/**
 * Agent action for "why is my bill $366?". Builds a line-by-line breakdown of a pest customer's
 * posted invoice from the invoice lines, schedules and visits, so the agent only rephrases facts
 * and never does the math itself.
 */
public with sharing class RLM_RTK_BillExplainer {
    public class Request {
        @InvocableVariable(label='Account Id' description='The record the user is on: a customer account or one of its invoices.')
        public Id accountId;
        @InvocableVariable(label='Account Name' description='The customer name the user mentioned, for example Sam Patel.')
        public String accountName;
        @InvocableVariable(label='Invoice Number' description='The invoice document number, for example DOC-000000016.')
        public String invoiceNumber;
        @InvocableVariable(label='Amount' description='The bill amount the user is asking about, for example 366 or 366.30.')
        public Decimal amount;
    }

    public class Response {
        @InvocableVariable(label='Explanation' description='Facts that explain the bill, line by line, with the math.')
        public String explanation;
        @InvocableVariable(label='Invoice Numbers' description='The invoice document numbers explained.')
        public String invoiceNumbers;
    }

    @InvocableMethod(label='Explain Pest Bill' category='Rentokil'
        description='Explains what makes up a Rentokil pest customer\'s bill: plans, one-time services, visit add-ons, plan-change credits, proration and tax.')
    public static List<Response> explain(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request request : requests) {
            responses.add(explainOne(request));
        }
        return responses;
    }

    @TestVisible
    private static Response explainOne(Request request) {
        Response response = new Response();
        Account account = findAccount(request);
        if (account == null) {
            response.explanation = 'I couldn\'t find that customer. Ask for the customer\'s name as it appears on the account.';
            return response;
        }
        List<Invoice> invoices = [
            SELECT Id, DocumentNumber, InvoiceDate, DueDate, TotalAmount, TotalAmountWithTax, TotalTaxAmount, Balance
            FROM Invoice
            WHERE BillingAccountId = :account.Id AND Status = 'Posted'
            ORDER BY InvoiceDate DESC, DocumentNumber DESC
            LIMIT 20
        ];
        if (invoices.isEmpty()) {
            response.explanation = account.Name + ' has no posted bills yet.';
            return response;
        }
        List<String> lines = new List<String>{ 'Customer: ' + account.Name };
        List<Invoice> chosen = choose(invoices, request, lines);
        String zone = zoneLine(account);
        if (zone != null) {
            lines.add(zone);
        }
        List<String> numbers = new List<String>();
        for (Invoice inv : chosen) {
            numbers.add(inv.DocumentNumber);
        }
        Map<Id, List<InvoiceLine>> linesByInvoice = linesFor(chosen);
        Map<Id, String> visitByProduct = visitsFor(account.Id);
        for (Invoice inv : chosen) {
            lines.add('');
            lines.addAll(describe(inv, linesByInvoice.get(inv.Id), visitByProduct));
        }
        Decimal open = 0;
        for (Invoice inv : invoices) {
            open += inv.Balance == null ? 0 : inv.Balance;
        }
        lines.add('');
        lines.add('Open balance across all bills: ' + money(open) + '.');
        response.explanation = String.join(lines, '\n');
        response.invoiceNumbers = String.join(numbers, ', ');
        return response;
    }

    private static Account findAccount(Request request) {
        if (request.accountId != null && request.accountId.getSobjectType() == Account.SObjectType) {
            return accountWhere(request.accountId, null);
        }
        if (request.accountId != null && request.accountId.getSobjectType() == Invoice.SObjectType) {
            List<Invoice> onRecord = [SELECT BillingAccountId, DocumentNumber FROM Invoice WHERE Id = :request.accountId];
            if (!onRecord.isEmpty()) {
                if (String.isBlank(request.invoiceNumber)) {
                    request.invoiceNumber = onRecord[0].DocumentNumber;
                }
                return accountWhere(onRecord[0].BillingAccountId, null);
            }
        }
        if (String.isNotBlank(request.invoiceNumber)) {
            List<Invoice> invoices = [SELECT BillingAccountId FROM Invoice WHERE DocumentNumber = :request.invoiceNumber.trim() LIMIT 1];
            if (!invoices.isEmpty()) {
                return accountWhere(invoices[0].BillingAccountId, null);
            }
        }
        return String.isBlank(request.accountName) ? null : accountWhere(null, request.accountName.trim());
    }

    private static Account accountWhere(Id accountId, String name) {
        String pattern = name == null ? null : '%' + name + '%';
        List<Account> accounts = accountId != null
            ? [SELECT Id, Name, ShippingPostalCode, BillingPostalCode FROM Account WHERE Id = :accountId]
            : [SELECT Id, Name, ShippingPostalCode, BillingPostalCode FROM Account WHERE Name = :name OR Name LIKE :pattern ORDER BY Name LIMIT 2];
        return accounts.size() == 1 || (accounts.size() > 1 && accounts[0].Name == name) ? accounts[0] : null;
    }

    /** The bill the user means: by number, by amount (one bill or all open bills), else the latest. */
    @TestVisible
    private static List<Invoice> choose(List<Invoice> invoices, Request request, List<String> lines) {
        if (String.isNotBlank(request.invoiceNumber)) {
            for (Invoice inv : invoices) {
                if (inv.DocumentNumber == request.invoiceNumber.trim()) {
                    return new List<Invoice>{ inv };
                }
            }
        }
        if (request.amount != null) {
            Decimal asked = request.amount;
            for (Invoice inv : invoices) {
                if (matches(inv.TotalAmountWithTax, asked) || matches(inv.TotalAmount, asked)) {
                    return new List<Invoice>{ inv };
                }
            }
            List<Invoice> open = new List<Invoice>();
            Decimal openTotal = 0;
            for (Invoice inv : invoices) {
                if (inv.Balance != null && inv.Balance > 0) {
                    open.add(inv);
                    openTotal += inv.Balance;
                }
            }
            if (!open.isEmpty() && matches(openTotal, asked)) {
                lines.add(money(asked) + ' is the total of ' + open.size() + ' open bills.');
                return open;
            }
            lines.add('No bill matches ' + money(asked) + '; this is the most recent bill.');
        }
        return new List<Invoice>{ invoices[0] };
    }

    /** Customers round, so $366 matches a $366.30 bill. */
    private static Boolean matches(Decimal actual, Decimal asked) {
        return actual != null && (actual - asked).abs() < (asked.scale() > 0 ? 0.01 : 1);
    }

    @TestVisible
    private static Map<Id, List<InvoiceLine>> linesFor(List<Invoice> invoices) {
        Map<Id, List<InvoiceLine>> byInvoice = new Map<Id, List<InvoiceLine>>();
        for (Invoice inv : invoices) {
            byInvoice.put(inv.Id, new List<InvoiceLine>());
        }
        for (InvoiceLine line : [
            SELECT InvoiceId, Name, Product2Id, Product2.Name, Quantity, UnitPrice, ChargeAmount, TaxAmount, TaxRate,
                LineAmount, InvoiceLineStartDate, InvoiceLineEndDate, Description, RLM_Charge_Type__c,
                BillingSchedule.BillingTermUnit
            FROM InvoiceLine
            WHERE InvoiceId IN :byInvoice.keySet() AND Type = 'Charge'
            ORDER BY ChargeAmount DESC
        ]) {
            byInvoice.get(line.InvoiceId).add(line);
        }
        return byInvoice;
    }

    /** Which visit each one-time product was added on, for "added during work order 00000118". */
    @TestVisible
    private static Map<Id, String> visitsFor(Id accountId) {
        Map<Id, String> byProduct = new Map<Id, String>();
        for (WorkOrderLineItem item : [
            SELECT PricebookEntry.Product2Id, WorkOrder.WorkOrderNumber, WorkOrder.WorkType.Name, CreatedDate
            FROM WorkOrderLineItem
            WHERE WorkOrder.AccountId = :accountId AND PricebookEntryId != null
            ORDER BY CreatedDate DESC
            LIMIT 50
        ]) {
            Id productId = item.PricebookEntry.Product2Id;
            if (!byProduct.containsKey(productId)) {
                byProduct.put(productId, 'added during the ' + blankAs(item.WorkOrder.WorkType?.Name, 'service') + ' visit (work order '
                    + item.WorkOrder.WorkOrderNumber + ') on ' + item.CreatedDate.date().format());
            }
        }
        return byProduct;
    }

    @TestVisible
    private static List<String> describe(Invoice inv, List<InvoiceLine> invoiceLines, Map<Id, String> visitByProduct) {
        List<String> out = new List<String>{
            'Bill ' + inv.DocumentNumber + ' dated ' + inv.InvoiceDate.format() + ': ' + money(inv.TotalAmountWithTax)
                + (inv.DueDate == null ? '' : ', due ' + inv.DueDate.format())
                + (inv.Balance == null || inv.Balance == 0 ? ' (paid)' : ' (' + money(inv.Balance) + ' still owed)') + '.'
        };
        Decimal rate;
        for (InvoiceLine line : invoiceLines == null ? new List<InvoiceLine>() : invoiceLines) {
            out.add('- ' + lineText(line, visitByProduct));
            if (line.TaxRate != null) {
                rate = line.TaxRate;
            }
        }
        if (rate == null && inv.TotalAmount != null && inv.TotalAmount != 0 && inv.TotalTaxAmount != null) {
            rate = (inv.TotalTaxAmount / inv.TotalAmount * 100).setScale(2);
        }
        out.add('- Subtotal ' + money(inv.TotalAmount) + ' + tax ' + money(inv.TotalTaxAmount)
            + (rate == null ? '' : ' (' + rate.stripTrailingZeros().toPlainString() + '%)')
            + ' = ' + money(inv.TotalAmountWithTax) + '.');
        return out;
    }

    @TestVisible
    private static String lineText(InvoiceLine line, Map<Id, String> visitByProduct) {
        String name = blankAs(line.Product2?.Name, line.Name);
        String period = line.InvoiceLineStartDate == null ? '' : line.InvoiceLineStartDate.format()
            + (line.InvoiceLineEndDate == null || line.InvoiceLineEndDate == line.InvoiceLineStartDate ? '' : ' to ' + line.InvoiceLineEndDate.format());
        String term = line.BillingSchedule?.BillingTermUnit;
        Decimal full = line.UnitPrice == null || line.Quantity == null ? null : (line.UnitPrice * line.Quantity).setScale(2);
        String amount = money(line.ChargeAmount);

        if (line.ChargeAmount != null && line.ChargeAmount < 0) {
            return name + ': credit of ' + money(line.ChargeAmount.abs()) + ' for the unused days (' + period
                + ') after the plan was changed; the ' + money(line.UnitPrice) + '/month plan was prorated.';
        }
        if (term == 'Month' || line.RLM_Charge_Type__c == 'Monthly Subscription') {
            String text = name + ': ' + amount + ' monthly plan charge for ' + period;
            if (full != null && line.ChargeAmount != null && line.ChargeAmount < full) {
                text += ' (prorated from ' + money(full) + ' because it covers part of a month)';
            }
            return text + '.';
        }
        if (String.isNotBlank(line.Description) && line.Description.startsWith('Milestone:')) {
            String milestone = line.Description.substringBetween('Milestone: ', ',');
            String completed = line.Description.substringAfter('Completion date: ');
            return name + ': ' + amount + ' one-time charge, billed when "' + blankAs(milestone, 'the milestone') + '" was reached'
                + (String.isBlank(completed) ? '' : ' on ' + asDate(completed)) + '. It won\'t repeat.';
        }
        String visit = visitByProduct.get(line.Product2Id);
        return name + ': ' + amount + ' one-time service' + (visit == null ? '' : ', ' + visit) + '. It won\'t repeat.';
    }

    @TestVisible
    private static String zoneLine(Account account) {
        String postal = String.isNotBlank(account.ShippingPostalCode) ? account.ShippingPostalCode : account.BillingPostalCode;
        if (String.isBlank(postal)) {
            return null;
        }
        RLM_RTK_ZonePricing.ZoneResult zone = RLM_RTK_ZonePricing.resolve(postal);
        Decimal multiplier = zone.multiplier == null ? 1.0 : zone.multiplier;
        return 'Service zone: ' + zone.zoneName + ' (ZIP ' + postal + '); prices are '
            + (multiplier == 1 ? 'standard list prices.' : 'list price x ' + multiplier.stripTrailingZeros().toPlainString() + ' for this zone.');
    }

    @TestVisible
    private static String money(Decimal value) {
        Decimal v = value == null ? 0 : value.setScale(2);
        String sign = v < 0 ? '-' : '';
        String text = v.abs().format();
        if (!text.contains('.')) {
            text += '.00';
        } else if (text.substringAfter('.').length() == 1) {
            text += '0';
        }
        return sign + '$' + text;
    }

    private static String asDate(String value) {
        try {
            return Date.valueOf(value.trim()).format();
        } catch (Exception e) {
            return value.trim();
        }
    }

    private static String blankAs(String value, String fallback) {
        return String.isBlank(value) ? fallback : value;
    }
}

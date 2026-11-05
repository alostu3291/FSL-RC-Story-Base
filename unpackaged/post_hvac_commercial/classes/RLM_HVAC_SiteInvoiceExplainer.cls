/**
 * Agent action for "why is the Lakeshore invoice $4,551?" or "what is Harvest Table paying for?".
 * Explains a Brightline Commercial consolidated invoice site by site, from the posted invoice lines
 * (RLM_HVAC_ContractInvoice.summariesFor), with every subtotal already worked out so the agent only
 * rephrases facts. Capital project invoices also get their milestone and share of the project.
 */
public with sharing class RLM_HVAC_SiteInvoiceExplainer {
    private static final Integer RECENT = 12;
    private static final Set<String> PROJECT_SKUS = new Set<String>{
        RLM_HVAC_CapitalProject.REPLACEMENT_SKU, RLM_HVAC_CapitalProject.CRANE_SKU
    };
    private static final List<String> MILESTONE_TEXT = new List<String>{
        'project deposit, billed when the project was booked',
        'installation milestone, billed when the new units were installed',
        'commissioning milestone, billed at start-up and handover'
    };

    public class Request {
        @InvocableVariable(label='Record Id' description='The record the user is on: the property group, one of its sites, or an invoice.')
        public Id recordId;
        @InvocableVariable(label='Account Name' description='The property group or site the user mentioned, for example Lakeshore Property Group or Harvest Table Restaurant.')
        public String accountName;
        @InvocableVariable(label='Site Name' description='The site the user asked about, for example Harvest Table.')
        public String siteName;
        @InvocableVariable(label='Invoice Number' description='The invoice document number, for example DOC-000000007.')
        public String invoiceNumber;
        @InvocableVariable(label='Amount' description='The invoice or site amount the user asked about, for example 4551.13 or 540.50.')
        public Decimal amount;
    }

    public class Response {
        @InvocableVariable(label='Explanation' description='Facts that explain the invoice site by site, with the math done.')
        public String explanation;
        @InvocableVariable(label='Invoice Numbers' description='The invoice document numbers explained.')
        public String invoiceNumbers;
    }

    @InvocableMethod(label='Explain Commercial Invoice by Site' category='Brightline'
        description='Explains a Brightline Commercial consolidated invoice site by site: each site\'s services, subtotal and tax, the PO number and terms, and capital project milestones.')
    public static List<Response> explain(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request request : requests) {
            responses.add(explainOne(request));
        }
        return responses;
    }

    public static Response explainOne(Request request) {
        Response response = new Response();
        Id invoiceId = request.recordId?.getSobjectType() == Invoice.SObjectType ? request.recordId : null;
        Account focus = invoiceId == null ? findAccount(request) : null;
        Id groupId;
        if (invoiceId != null) {
            groupId = [SELECT BillingAccountId FROM Invoice WHERE Id = :invoiceId].BillingAccountId;
        } else if (focus == null) {
            response.explanation = 'I couldn\'t find that property group or site. Ask for the name as it appears on the account.';
            return response;
        } else {
            groupId = focus.ParentId ?? focus.Id;
            if (focus.ParentId != null && String.isBlank(request.siteName)) {
                request.siteName = focus.Name;
            }
        }

        List<Invoice> recent = [
            SELECT Id, DocumentNumber, InvoiceDate, TotalAmountWithTax
            FROM Invoice WHERE BillingAccountId = :groupId AND Status = 'Posted'
            ORDER BY InvoiceDate DESC, DocumentNumber DESC LIMIT :RECENT
        ];
        Map<Id, RLM_HVAC_ContractInvoice.Summary> summaries = RLM_HVAC_ContractInvoice.summariesFor(
            new Map<Id, Invoice>(recent).keySet());
        List<RLM_HVAC_ContractInvoice.Summary> commercial = new List<RLM_HVAC_ContractInvoice.Summary>();
        for (Invoice inv : recent) {
            RLM_HVAC_ContractInvoice.Summary s = summaries.get(inv.Id);
            if (s != null && s.isContract) {
                commercial.add(s);
            }
        }
        if (commercial.isEmpty()) {
            response.explanation = 'There are no posted Brightline Commercial invoices for this property group yet.';
            return response;
        }

        List<String> facts = new List<String>();
        RLM_HVAC_ContractInvoice.Summary chosen = choose(commercial, invoiceId, request, facts);
        RLM_HVAC_ContractInvoice.Site asked = findSite(chosen, request.siteName);
        if (asked == null && request.amount != null) {
            asked = siteWithTotal(chosen, request.amount);
        }

        facts.add(headline(chosen));
        if (asked != null) {
            facts.add('The user asked about ' + asked.name + ': ' + siteLine(asked) + ' That is '
                + percent(asked.total, chosen.total) + ' of the invoice total.');
        } else if (String.isNotBlank(request.siteName)) {
            facts.add('No site on this invoice matches "' + request.siteName + '".');
        }
        facts.add('Charges by site (each site\'s charges plus its tax):');
        for (RLM_HVAC_ContractInvoice.Site site : chosen.sites) {
            facts.add('- ' + site.name + describe(site) + ': ' + siteLine(site));
            for (RLM_HVAC_ContractInvoice.Line l : site.lines) {
                facts.add('    - ' + l.name + (l.quantity == null || l.quantity == 1 ? '' : ' x' + qty(l.quantity))
                    + ': ' + money(l.charge) + period(l));
            }
        }
        if (hasServicePeriods(chosen)) {
            facts.add('Contract services bill monthly in advance: each line is one month of the site\'s 12-month '
                + 'contract price, for the service period shown. Sites added mid-term bill from their start date.');
        }
        facts.addAll(projectFacts(chosen));
        facts.add('Sum of the site totals: ' + money(sumOfSites(chosen)) + ', which matches the invoice total of '
            + money(chosen.total) + '.');
        facts.add(otherInvoices(commercial, chosen));

        response.explanation = String.join(facts, '\n');
        response.invoiceNumbers = chosen.documentNumber;
        return response;
    }

    private static Account findAccount(Request request) {
        if (request.recordId != null && request.recordId.getSobjectType() == Account.SObjectType) {
            List<Account> onRecord = [SELECT Id, Name, ParentId FROM Account WHERE Id = :request.recordId];
            return onRecord.isEmpty() ? null : onRecord[0];
        }
        String name = String.isNotBlank(request.accountName) ? request.accountName : request.siteName;
        if (String.isBlank(name)) {
            return null;
        }
        String pattern = '%' + name.trim() + '%';
        List<Account> matches = [
            SELECT Id, Name, ParentId FROM Account
            WHERE Name LIKE :pattern AND (RLM_HVAC_Site_Type__c != null OR ParentId != null)
            ORDER BY ParentId NULLS FIRST, Name LIMIT 1
        ];
        return matches.isEmpty() ? null : matches[0];
    }

    private static RLM_HVAC_ContractInvoice.Summary choose(List<RLM_HVAC_ContractInvoice.Summary> invoices, Id invoiceId,
            Request request, List<String> facts) {
        for (RLM_HVAC_ContractInvoice.Summary s : invoices) {
            if (s.invoiceId == invoiceId
                    || (String.isNotBlank(request.invoiceNumber) && s.documentNumber.equalsIgnoreCase(request.invoiceNumber.trim()))) {
                return s;
            }
        }
        if (String.isNotBlank(request.invoiceNumber)) {
            facts.add('No posted invoice is numbered ' + request.invoiceNumber + '; this is the most recent one.');
        }
        if (request.amount != null) {
            for (RLM_HVAC_ContractInvoice.Summary s : invoices) {
                if (close(s.total, request.amount) || close(s.charge, request.amount) || siteWithTotal(s, request.amount) != null) {
                    return s;
                }
            }
            facts.add('No recent invoice or site subtotal is ' + money(request.amount) + '; this is the most recent invoice.');
        }
        return invoices[0];
    }

    private static RLM_HVAC_ContractInvoice.Site findSite(RLM_HVAC_ContractInvoice.Summary s, String name) {
        if (String.isBlank(name)) {
            return null;
        }
        String wanted = name.trim().toLowerCase();
        for (RLM_HVAC_ContractInvoice.Site site : s.sites) {
            String siteName = (site.name ?? '').toLowerCase();
            if (siteName == wanted || siteName.contains(wanted) || wanted.contains(siteName)) {
                return site;
            }
        }
        return null;
    }

    private static RLM_HVAC_ContractInvoice.Site siteWithTotal(RLM_HVAC_ContractInvoice.Summary s, Decimal amount) {
        for (RLM_HVAC_ContractInvoice.Site site : s.sites) {
            if (close(site.total, amount) || close(site.charge, amount)) {
                return site;
            }
        }
        return null;
    }

    private static String headline(RLM_HVAC_ContractInvoice.Summary s) {
        List<String> parts = new List<String>{
            'Invoice ' + s.documentNumber + ' for ' + s.accountName + ', dated ' + day(s.invoiceDate)
                + (s.dueDate == null ? '' : ', due ' + day(s.dueDate))
                + (s.paymentTerm == null ? '' : ' (' + (s.paymentTerm == 'Default Payment Term' ? 'Net 30' : s.paymentTerm) + ')')
                + '.'
        };
        if (String.isNotBlank(s.poNumber)) {
            parts.add('It references purchase order ' + s.poNumber + '.');
        }
        if (String.isNotBlank(s.billTo)) {
            parts.add('It is billed to ' + s.billTo + ' at the property group headquarters, as one invoice for all sites.');
        }
        parts.add('Total ' + money(s.total) + ' = ' + money(s.charge) + ' in charges + ' + money(s.tax) + ' tax, across '
            + s.sites.size() + (s.sites.size() == 1 ? ' site.' : ' sites.'));
        return String.join(parts, ' ');
    }

    private static String describe(RLM_HVAC_ContractInvoice.Site site) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(site.siteType)) {
            parts.add(site.siteType);
        }
        if (String.isNotBlank(site.responseTier)) {
            parts.add(site.responseTier + ' response');
        }
        return parts.isEmpty() ? '' : ' (' + String.join(parts, ', ') + ')';
    }

    private static String siteLine(RLM_HVAC_ContractInvoice.Site site) {
        return money(site.total) + ' = ' + money(site.charge) + ' charges + ' + money(site.tax) + ' tax.';
    }

    private static String period(RLM_HVAC_ContractInvoice.Line l) {
        if (l.startDate == null) {
            return '';
        }
        if (l.endDate == null || l.endDate == l.startDate) {
            return ', billed ' + day(l.startDate);
        }
        String text = ' for ' + day(l.startDate) + ' to ' + day(l.endDate);
        Date monthEnd = l.startDate.toStartOfMonth().addMonths(1).addDays(-1);
        if (l.startDate.day() != 1 || l.endDate < monthEnd) {
            text += ' (a partial month, prorated)';
        }
        return text;
    }

    private static Boolean hasServicePeriods(RLM_HVAC_ContractInvoice.Summary s) {
        for (RLM_HVAC_ContractInvoice.Site site : s.sites) {
            for (RLM_HVAC_ContractInvoice.Line l : site.lines) {
                if (l.startDate != null && l.endDate != null && l.endDate > l.startDate) {
                    return true;
                }
            }
        }
        return false;
    }

    /** Milestone facts for capital project lines: which milestone this invoice bills and its share of the line. */
    private static List<String> projectFacts(RLM_HVAC_ContractInvoice.Summary s) {
        List<String> facts = new List<String>();
        Map<Id, InvoiceLine> lines = new Map<Id, InvoiceLine>();
        for (InvoiceLine line : [
            SELECT Id, Name, ChargeAmount, ReferenceEntityItemId, BillingSchedule.ReferenceEntityItemId
            FROM InvoiceLine
            WHERE InvoiceId = :s.invoiceId AND Type = 'Charge' AND Product2.StockKeepingUnit IN :PROJECT_SKUS
        ]) {
            lines.put(line.Id, line);
        }
        if (lines.isEmpty()) {
            return facts;
        }
        Set<Id> itemIds = new Set<Id>();
        for (InvoiceLine line : lines.values()) {
            itemIds.add(line.BillingSchedule?.ReferenceEntityItemId ?? line.ReferenceEntityItemId);
        }
        Map<Id, OrderItem> items = new Map<Id, OrderItem>([SELECT Id, TotalPrice FROM OrderItem WHERE Id IN :itemIds]);
        Map<Id, List<String>> billedBy = new Map<Id, List<String>>();
        for (InvoiceLine earlier : [
            SELECT Invoice.DocumentNumber, BillingSchedule.ReferenceEntityItemId FROM InvoiceLine
            WHERE BillingSchedule.ReferenceEntityItemId IN :itemIds AND Type = 'Charge' AND Invoice.Status = 'Posted'
            ORDER BY Invoice.InvoiceDate, Invoice.DocumentNumber
        ]) {
            Id key = earlier.BillingSchedule.ReferenceEntityItemId;
            if (!billedBy.containsKey(key)) {
                billedBy.put(key, new List<String>());
            }
            if (!billedBy.get(key).contains(earlier.Invoice.DocumentNumber)) {
                billedBy.get(key).add(earlier.Invoice.DocumentNumber);
            }
        }
        Integer position;
        facts.add('Capital project milestone billing (40% deposit, 40% at installation, 20% at commissioning):');
        for (InvoiceLine line : lines.values()) {
            Id key = line.BillingSchedule?.ReferenceEntityItemId ?? line.ReferenceEntityItemId;
            OrderItem item = items.get(key);
            List<String> invoices = billedBy.get(key) ?? new List<String>();
            position = invoices.indexOf(s.documentNumber);
            String share = item == null || item.TotalPrice == null || item.TotalPrice == 0 ? ''
                : ', ' + percent(line.ChargeAmount, item.TotalPrice) + ' of the ' + money(item.TotalPrice) + ' line';
            facts.add('- ' + line.Name + ': ' + money(line.ChargeAmount) + share + '.');
        }
        if (position != null && position >= 0 && position < MILESTONE_TEXT.size()) {
            facts.add('This invoice is the ' + MILESTONE_TEXT[position] + ' (milestone ' + (position + 1) + ' of 3).');
        }
        return facts;
    }

    private static String otherInvoices(List<RLM_HVAC_ContractInvoice.Summary> invoices, RLM_HVAC_ContractInvoice.Summary chosen) {
        List<String> others = new List<String>();
        for (RLM_HVAC_ContractInvoice.Summary s : invoices) {
            if (s.invoiceId != chosen.invoiceId && others.size() < 5) {
                others.add(s.documentNumber + ' ' + money(s.total) + ' dated ' + day(s.invoiceDate)
                    + (String.isBlank(s.poNumber) ? '' : ' (PO ' + s.poNumber + ')'));
            }
        }
        return others.isEmpty() ? 'There are no other posted invoices for this property group.'
            : 'Other recent invoices for this property group: ' + String.join(others, '; ') + '.';
    }

    private static Decimal sumOfSites(RLM_HVAC_ContractInvoice.Summary s) {
        Decimal total = 0;
        for (RLM_HVAC_ContractInvoice.Site site : s.sites) {
            total += site.total;
        }
        return total;
    }

    private static Boolean close(Decimal a, Decimal b) {
        return a != null && b != null && Math.abs(a - b) < 1;
    }

    @TestVisible
    private static String percent(Decimal part, Decimal whole) {
        if (part == null || whole == null || whole == 0) {
            return '0%';
        }
        return (part * 100 / whole).setScale(1).stripTrailingZeros().toPlainString() + '%';
    }

    private static String qty(Decimal q) {
        return q.stripTrailingZeros().toPlainString();
    }

    @TestVisible
    private static String money(Decimal value) {
        Decimal v = (value ?? 0).setScale(2);
        String whole = String.valueOf(Math.abs(v).intValue());
        String grouped = '';
        while (whole.length() > 3) {
            grouped = ',' + whole.right(3) + grouped;
            whole = whole.left(whole.length() - 3);
        }
        String cents = String.valueOf(Math.abs(v)).substringAfter('.').rightPad(2, '0');
        return (v < 0 ? '-$' : '$') + whole + grouped + '.' + cents;
    }

    private static String day(Date d) {
        return d == null ? '' : Datetime.newInstanceGmt(d, Time.newInstance(0, 0, 0, 0)).formatGmt('MMM d, yyyy');
    }
}

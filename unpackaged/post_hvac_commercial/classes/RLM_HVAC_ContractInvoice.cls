/**
 * The consolidated Brightline Commercial invoice. A contract's billing schedules share one billing
 * account (the property group), bill-to contact and payment term, so each month's billing posts as
 * one invoice to HQ. Each line traces back to its order product through its billing schedule
 * (InvoiceLine -> BillingSchedule.ReferenceEntityItemId -> OrderItem), which carries the site and
 * the order's PO number:
 *  - new invoices get the PO number (RLM_HVAC_CommercialInvoiceTrigger queues the stamp, because the lines
 *    are written after the invoice);
 *  - siteSummary groups the lines by site with subtotals, for the invoice page and the billing agent.
 */
public with sharing class RLM_HVAC_ContractInvoice {

    public class Line {
        @AuraEnabled public String name;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal charge = 0;
        @AuraEnabled public Decimal tax = 0;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Date endDate;
    }

    public class Site {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String name;
        @AuraEnabled public String siteType;
        @AuraEnabled public String responseTier;
        @AuraEnabled public Decimal charge = 0;
        @AuraEnabled public Decimal tax = 0;
        @AuraEnabled public Decimal total = 0;
        @AuraEnabled public List<Line> lines = new List<Line>();
    }

    public class Summary {
        @AuraEnabled public Id invoiceId;
        @AuraEnabled public String documentNumber;
        @AuraEnabled public String accountName;
        @AuraEnabled public String poNumber;
        @AuraEnabled public String paymentTerm;
        @AuraEnabled public String billTo;
        @AuraEnabled public Date invoiceDate;
        @AuraEnabled public Date dueDate;
        @AuraEnabled public Decimal charge = 0;
        @AuraEnabled public Decimal tax = 0;
        @AuraEnabled public Decimal total = 0;
        @AuraEnabled public Boolean isContract = false;
        @AuraEnabled public List<Site> sites = new List<Site>();
    }

    public class InvoiceRequest {
        @InvocableVariable(required=true label='Property Group Account Id') public Id accountId;
        @InvocableVariable(label='Bill Through' description='Bill everything due by this date; defaults to today.')
        public Date targetDate;
    }

    @InvocableMethod(label='Invoice Brightline Commercial Contract' category='Brightline'
        description='Posts one consolidated invoice for everything due on the property group\'s contract and its amendments.')
    public static void invoiceGroups(List<InvoiceRequest> requests) {
        for (InvoiceRequest r : requests) {
            invoiceGroup(r.accountId, r.targetDate);
        }
    }

    /**
     * Bills the contract order and its amendments together, so the month's charges for every site
     * post as one invoice to the property group.
     */
    @AuraEnabled
    public static Integer invoiceGroup(Id accountId, Date targetDate) {
        Set<Id> orderIds = new Set<Id>();
        for (OrderItem item : [
            SELECT OrderId FROM OrderItem
            WHERE Order.AccountId = :accountId AND Order.Status = 'Activated' AND RLM_HVAC_Site__c != null
        ]) {
            orderIds.add(item.OrderId);
        }
        if (!orderIds.isEmpty()) {
            RLM_FSL_InvoiceOrder.enqueue(orderIds, targetDate ?? Date.today());
        }
        return orderIds.size();
    }

    public static void invoicesInserted(List<Invoice> invoices) {
        Set<Id> ids = new Map<Id, Invoice>(invoices).keySet();
        if (!ids.isEmpty() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()
                && !(Test.isRunningTest() && System.isQueueable())) {
            System.enqueueJob(new StampJob(ids));
        }
    }

    public class StampJob implements Queueable {
        private final Set<Id> invoiceIds;

        public StampJob(Set<Id> invoiceIds) {
            this.invoiceIds = invoiceIds;
        }

        public void execute(QueueableContext context) {
            stampPurchaseOrders(invoiceIds);
        }
    }

    /** Copies the contract order's PO number onto its invoices. Other invoices are left alone. */
    public static void stampPurchaseOrders(Set<Id> invoiceIds) {
        Map<Id, Id> orderByInvoice = new Map<Id, Id>();
        for (InvoiceLine line : [
            SELECT InvoiceId, BillingSchedule.ReferenceEntityId FROM InvoiceLine
            WHERE InvoiceId IN :invoiceIds AND BillingSchedule.ReferenceEntityId != null
                AND Product2.StockKeepingUnit LIKE 'HVAC-COM-%'
        ]) {
            orderByInvoice.put(line.InvoiceId, line.BillingSchedule.ReferenceEntityId);
        }
        if (orderByInvoice.isEmpty()) {
            return;
        }
        Map<Id, Order> orders = new Map<Id, Order>(
            [SELECT Id, PoNumber, OriginalOrder.PoNumber FROM Order WHERE Id IN :orderByInvoice.values()]
        );
        List<Invoice> stamped = new List<Invoice>();
        for (Invoice inv : [SELECT Id, Description, RLM_HVAC_PO_Number__c FROM Invoice WHERE Id IN :orderByInvoice.keySet()]) {
            Order o = orders.get(orderByInvoice.get(inv.Id));
            String po = o == null ? null : (String.isNotBlank(o.PoNumber) ? o.PoNumber : o.OriginalOrder?.PoNumber);
            if (String.isBlank(po) || inv.RLM_HVAC_PO_Number__c == po) {
                continue;
            }
            stamped.add(new Invoice(Id = inv.Id, RLM_HVAC_PO_Number__c = po,
                Description = String.isBlank(inv.Description) ? 'PO ' + po : inv.Description));
        }
        update stamped;
    }

    @AuraEnabled(cacheable=true)
    public static Summary siteSummary(Id invoiceId) {
        try {
            return summaryFor(invoiceId);
        } catch (Exception e) {
            AuraHandledException error = new AuraHandledException(e.getMessage());
            error.setMessage(e.getMessage());
            throw error;
        }
    }

    public static Summary summaryFor(Id invoiceId) {
        Invoice inv = [
            SELECT Id, DocumentNumber, BillingAccount.Name, InvoiceDate, DueDate, TotalAmount, TotalTaxAmount,
                TotalAmountWithTax, PaymentTerm.Name, BillToContact.Name, RLM_HVAC_PO_Number__c
            FROM Invoice WHERE Id = :invoiceId
        ];
        Summary s = new Summary();
        s.invoiceId = inv.Id;
        s.documentNumber = inv.DocumentNumber;
        s.accountName = inv.BillingAccount?.Name;
        s.poNumber = inv.RLM_HVAC_PO_Number__c;
        s.paymentTerm = inv.PaymentTerm?.Name;
        s.billTo = inv.BillToContact?.Name;
        s.invoiceDate = inv.InvoiceDate;
        s.dueDate = inv.DueDate;
        s.charge = inv.TotalAmount ?? 0;
        s.tax = inv.TotalTaxAmount ?? 0;
        s.total = inv.TotalAmountWithTax ?? s.charge + s.tax;

        List<InvoiceLine> lines = [
            SELECT Name, Quantity, ChargeAmount, TaxAmount, InvoiceLineStartDate, InvoiceLineEndDate,
                BillingSchedule.ReferenceEntityItemId, Product2.StockKeepingUnit
            FROM InvoiceLine WHERE InvoiceId = :invoiceId AND Type = 'Charge'
            ORDER BY Name
        ];
        Set<Id> itemIds = new Set<Id>();
        for (InvoiceLine line : lines) {
            if (line.BillingSchedule?.ReferenceEntityItemId != null) {
                itemIds.add(line.BillingSchedule.ReferenceEntityItemId);
            }
        }
        Map<Id, OrderItem> items = new Map<Id, OrderItem>([
            SELECT Id, RLM_HVAC_Site__c, RLM_HVAC_Site__r.Name, RLM_HVAC_Site__r.RLM_HVAC_Site_Type__c,
                RLM_HVAC_Site__r.RLM_HVAC_Response_Tier__c, RLM_HVAC_Site__r.RLM_HVAC_Site_Code__c
            FROM OrderItem WHERE Id IN :itemIds
        ]);
        Map<String, Site> bySite = new Map<String, Site>();
        Map<String, String> sortKey = new Map<String, String>();
        for (InvoiceLine line : lines) {
            OrderItem item = items.get(line.BillingSchedule?.ReferenceEntityItemId);
            String key = item?.RLM_HVAC_Site__c == null ? 'none' : String.valueOf(item.RLM_HVAC_Site__c);
            Site site = bySite.get(key);
            if (site == null) {
                site = new Site();
                if (item?.RLM_HVAC_Site__c != null) {
                    site.accountId = item.RLM_HVAC_Site__c;
                    site.name = item.RLM_HVAC_Site__r.Name;
                    site.siteType = item.RLM_HVAC_Site__r.RLM_HVAC_Site_Type__c;
                    site.responseTier = item.RLM_HVAC_Site__r.RLM_HVAC_Response_Tier__c;
                    sortKey.put(key, (item.RLM_HVAC_Site__r.RLM_HVAC_Site_Code__c ?? '') + site.name);
                } else {
                    site.name = 'Other charges';
                    sortKey.put(key, '~');
                }
                bySite.put(key, site);
            }
            if (item?.RLM_HVAC_Site__c != null) {
                s.isContract = true;
            }
            Line l = new Line();
            l.name = line.Name;
            l.quantity = line.Quantity;
            l.charge = line.ChargeAmount ?? 0;
            l.tax = line.TaxAmount ?? 0;
            l.startDate = line.InvoiceLineStartDate;
            l.endDate = line.InvoiceLineEndDate;
            site.lines.add(l);
            site.charge += l.charge;
            site.tax += l.tax;
            site.total = site.charge + site.tax;
        }
        Map<String, String> keyBySort = new Map<String, String>();
        for (String key : sortKey.keySet()) {
            keyBySort.put(sortKey.get(key) + key, key);
        }
        List<String> order = new List<String>(keyBySort.keySet());
        order.sort();
        for (String k : order) {
            s.sites.add(bySite.get(keyBySort.get(k)));
        }
        return s;
    }
}

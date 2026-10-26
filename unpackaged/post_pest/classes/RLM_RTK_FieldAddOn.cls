/**
 * Find & Add: one-time services a technician adds on site when a visit turns up something the
 * plan doesn't cover (a wasp nest, rodent entry points, a soiled attic, bed bugs).
 *
 * The customer approves each add-on on the technician's device. Approved add-ons are work order
 * line items, so the work is done on this visit; when the work order is completed they are billed
 * as one priced Revenue Cloud order (Place Sales Transaction, as in RLM_FSL_BillRepair), activated
 * and invoiced. Prices are list price times the customer's service zone multiplier, the same as
 * the field quote.
 */
public with sharing class RLM_RTK_FieldAddOn {
    public static final String CATEGORY_CODE = 'PC-RTK-FIELD';
    public static final String WASP_NEST = 'RTK-WASP-NEST';
    public static final String RODENT_EXCLUSION = 'RTK-RODENT-EXCL';
    public static final String ATTIC_SANITATION = 'RTK-ATTIC-SANI';
    public static final String BED_BUG = 'RTK-BEDBUG';

    public class AddOn {
        @AuraEnabled public String sku;
        @AuraEnabled public String name;
        @AuraEnabled public String description;
        @AuraEnabled public Decimal price;
        @AuraEnabled public Boolean recommended = false;
        @AuraEnabled public String reason;
        @AuraEnabled public Id findingId;
        @AuraEnabled public Boolean added = false;
    }

    public class Line {
        @AuraEnabled public Id id;
        @AuraEnabled public String sku;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal price;
        @AuraEnabled public String approvedBy;
        @AuraEnabled public Datetime approvedAt;
        @AuraEnabled public String reason;
        @AuraEnabled public Boolean billed = false;
    }

    public class State {
        @AuraEnabled public Id workOrderId;
        @AuraEnabled public String workOrderNumber;
        @AuraEnabled public Id inspectionId;
        @AuraEnabled public String customerName;
        @AuraEnabled public String zoneLabel;
        @AuraEnabled public Boolean completed = false;
        @AuraEnabled public List<AddOn> addOns = new List<AddOn>();
        @AuraEnabled public List<Line> lines = new List<Line>();
        @AuraEnabled public Decimal total = 0;
    }

    public interface OrderPlacer {
        Id place(WorkOrder workOrder, List<WorkOrderLineItem> lines);
    }

    @TestVisible
    private static OrderPlacer placer = new SalesTransactionPlacer();

    @AuraEnabled
    public static State getState(Id recordId) {
        try {
            return buildState(workOrderFor(recordId));
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Adds the approved add-ons to the work order as line items at the customer's zone price. */
    @AuraEnabled
    public static State addAddOns(Id recordId, List<String> skus, String approvedBy) {
        try {
            WorkOrder wo = workOrderFor(recordId);
            if (wo.Status == 'Completed') {
                throw new AddOnException('This visit is already complete.');
            }
            if (skus == null || skus.isEmpty()) {
                throw new AddOnException('Pick at least one add-on.');
            }
            if (String.isBlank(approvedBy)) {
                throw new AddOnException('Enter the name of the customer approving the add-ons.');
            }
            Map<String, AddOn> catalog = new Map<String, AddOn>();
            for (AddOn a : buildState(wo).addOns) {
                catalog.put(a.sku, a);
            }
            Map<String, PricebookEntry> entries = entriesBySku();
            Id pricebookId = entries.isEmpty() ? null : entries.values()[0].Pricebook2Id;
            if (wo.Pricebook2Id == null && pricebookId != null) {
                update new WorkOrder(Id = wo.Id, Pricebook2Id = pricebookId);
            }
            Datetime now = Datetime.now();
            List<WorkOrderLineItem> lines = new List<WorkOrderLineItem>();
            for (String sku : new Set<String>(skus)) {
                AddOn a = catalog.get(sku);
                PricebookEntry entry = entries.get(sku);
                if (a == null || entry == null) {
                    throw new AddOnException('Add-on ' + sku + ' is not available.');
                }
                if (a.added) {
                    continue;
                }
                lines.add(new WorkOrderLineItem(
                    WorkOrderId = wo.Id,
                    PricebookEntryId = entry.Id,
                    Quantity = 1,
                    UnitPrice = a.price,
                    Subject = a.name,
                    Description = a.reason == null ? a.description : a.reason,
                    Status = 'New',
                    RLM_RTK_Finding__c = a.findingId,
                    RLM_RTK_Approved_By__c = approvedBy.trim(),
                    RLM_RTK_Approved_At__c = now
                ));
            }
            insert lines;
            return buildState(wo);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static State removeAddOn(Id lineId) {
        try {
            WorkOrderLineItem line = [
                SELECT Id, WorkOrderId, RLM_RTK_Add_On_Order__c FROM WorkOrderLineItem WHERE Id = :lineId
            ];
            if (line.RLM_RTK_Add_On_Order__c != null) {
                throw new AddOnException('This add-on has already been billed.');
            }
            delete line;
            return buildState(workOrderFor(line.WorkOrderId));
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @InvocableMethod(label='Bill Field Add-ons' category='Field Service'
        description='Creates, activates and invoices one order for the approved, unbilled field add-ons on completed work orders.')
    public static void billAddOns(List<Id> workOrderIds) {
        Set<Id> withAddOns = new Set<Id>();
        for (WorkOrderLineItem line : unbilledLines(new Set<Id>(workOrderIds))) {
            withAddOns.add(line.WorkOrderId);
        }
        if (!withAddOns.isEmpty()) {
            System.enqueueJob(new AddOnOrderJob(new List<Id>(withAddOns), new Set<Id>()));
        }
    }

    /** Place Sales Transaction handles one order per call, so the job bills one work order and chains itself. */
    public class AddOnOrderJob implements Queueable {
        private final List<Id> pending;
        private final Set<Id> orderIds;

        public AddOnOrderJob(List<Id> pending, Set<Id> orderIds) {
            this.pending = pending;
            this.orderIds = orderIds;
        }

        public void execute(QueueableContext context) {
            Id workOrderId = pending.remove(0);
            try {
                Id orderId = bill(workOrderId);
                if (orderId != null) {
                    orderIds.add(orderId);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Field add-on billing failed for ' + workOrderId + ': ' + e.getMessage());
            }
            if (!pending.isEmpty()) {
                System.enqueueJob(new AddOnOrderJob(pending, orderIds));
            } else if (!orderIds.isEmpty() && !Test.isRunningTest()) {
                RLM_FSL_InvoiceOrder.enqueue(orderIds);
            }
        }
    }

    @TestVisible
    private static Id bill(Id workOrderId) {
        List<WorkOrderLineItem> lines = unbilledLines(new Set<Id>{ workOrderId });
        if (lines.isEmpty()) {
            return null;
        }
        WorkOrder wo = [
            SELECT Id, WorkOrderNumber, AccountId, ContactId, Pricebook2Id,
                Account.ShippingStreet, Account.ShippingCity, Account.ShippingState, Account.ShippingPostalCode,
                Account.ShippingCountry, Account.BillingStreet, Account.BillingCity, Account.BillingState,
                Account.BillingPostalCode, Account.BillingCountry
            FROM WorkOrder WHERE Id = :workOrderId
        ];
        Id orderId = placer.place(wo, lines);
        insert new AppUsageAssignment(RecordId = orderId, AppUsageType = 'RevenueLifecycleManagement');
        update new Order(Id = orderId, Status = 'Activated');
        for (WorkOrderLineItem line : lines) {
            line.RLM_RTK_Add_On_Order__c = orderId;
        }
        update lines;
        return orderId;
    }

    public class SalesTransactionPlacer implements OrderPlacer {
        public Id place(WorkOrder wo, List<WorkOrderLineItem> lines) {
            String today = String.valueOf(Date.today());
            Account account = wo.Account;
            Id billToContactId = wo.ContactId;
            if (billToContactId == null) {
                List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :wo.AccountId ORDER BY CreatedDate LIMIT 1];
                if (!contacts.isEmpty()) {
                    billToContactId = contacts[0].Id;
                }
            }
            RevSalesTrxn.RecordResource orderRecord = new RevSalesTrxn.RecordResource(Order.SObjectType, 'POST');
            orderRecord.fieldValues = new Map<String, Object>{
                'AccountId' => wo.AccountId, 'Pricebook2Id' => wo.Pricebook2Id, 'EffectiveDate' => today,
                'Status' => 'Draft', 'CurrencyIsoCode' => 'USD', 'Name' => 'Field Add-ons - WO ' + wo.WorkOrderNumber,
                'ShippingStreet' => account.ShippingStreet, 'ShippingCity' => account.ShippingCity,
                'ShippingState' => account.ShippingState, 'ShippingPostalCode' => account.ShippingPostalCode,
                'ShippingCountry' => account.ShippingCountry, 'BillingStreet' => account.BillingStreet,
                'BillingCity' => account.BillingCity, 'BillingState' => account.BillingState,
                'BillingPostalCode' => account.BillingPostalCode, 'BillingCountry' => account.BillingCountry
            };
            if (billToContactId != null) {
                orderRecord.fieldValues.put('BillToContactId', billToContactId);
                orderRecord.fieldValues.put('ShipToContactId', billToContactId);
            }
            RevSalesTrxn.RecordResource actionRecord = new RevSalesTrxn.RecordResource(OrderAction.SObjectType, 'POST');
            actionRecord.fieldValues = new Map<String, Object>{ 'OrderId' => '@{refOrder.id}', 'Type' => 'Add' };
            List<RevSalesTrxn.RecordWithReferenceRequest> records = new List<RevSalesTrxn.RecordWithReferenceRequest>{
                new RevSalesTrxn.RecordWithReferenceRequest('refOrder', orderRecord),
                new RevSalesTrxn.RecordWithReferenceRequest('refAction', actionRecord)
            };
            Integer i = 1;
            for (WorkOrderLineItem line : lines) {
                RevSalesTrxn.RecordResource item = new RevSalesTrxn.RecordResource(OrderItem.SObjectType, 'POST');
                item.fieldValues = new Map<String, Object>{
                    'OrderId' => '@{refOrder.id}', 'OrderActionId' => '@{refAction.id}',
                    'Product2Id' => line.PricebookEntry.Product2Id, 'PricebookEntryId' => line.PricebookEntryId,
                    'Quantity' => '1', 'UnitPrice' => String.valueOf(line.UnitPrice), 'ServiceDate' => today
                };
                records.add(new RevSalesTrxn.RecordWithReferenceRequest('refItem' + i++, item));
            }
            RevSalesTrxn.PlaceSalesTransactionResponse response = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                new RevSalesTrxn.GraphRequest('rtkFieldAddOns', records),
                RevSalesTrxn.PricingPreferenceEnum.SYSTEM, RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
                new RevSalesTrxn.ConfigurationOptionsInput(), null, null, RevSalesTrxn.TaxPreferenceEnum.SKIP, null);
            if (response.isSuccess != true || String.isBlank(response.salesTransactionId)) {
                throw new AddOnException('Place Sales Transaction failed: ' + JSON.serialize(response.errorResponse));
            }
            return response.salesTransactionId;
        }
    }

    // ---------- state ----------

    private static State buildState(WorkOrder wo) {
        State state = new State();
        state.workOrderId = wo.Id;
        state.workOrderNumber = wo.WorkOrderNumber;
        state.inspectionId = wo.RLM_RTK_Inspection__c;
        state.completed = wo.Status == 'Completed';
        state.customerName = wo.Contact != null && wo.Contact.Name != null ? wo.Contact.Name : wo.Account.Name;

        RLM_RTK_ZonePricing.ZoneResult zone = RLM_RTK_ZonePricing.resolve(
            String.isNotBlank(wo.PostalCode) ? wo.PostalCode : wo.Account.ShippingPostalCode);
        Decimal multiplier = zone == null || zone.multiplier == null ? 1 : zone.multiplier;
        if (zone != null && zone.zoneName != null) {
            state.zoneLabel = zone.zoneName + ' x' + multiplier.setScale(2);
        }

        Set<String> addedSkus = new Set<String>();
        for (WorkOrderLineItem line : [
            SELECT Id, Subject, Description, UnitPrice, PricebookEntry.Product2.StockKeepingUnit,
                RLM_RTK_Approved_By__c, RLM_RTK_Approved_At__c, RLM_RTK_Add_On_Order__c
            FROM WorkOrderLineItem
            WHERE WorkOrderId = :wo.Id AND RLM_RTK_Approved_At__c != null
            ORDER BY CreatedDate
        ]) {
            Line l = new Line();
            l.id = line.Id;
            l.sku = line.PricebookEntry.Product2.StockKeepingUnit;
            l.name = line.Subject;
            l.price = line.UnitPrice;
            l.reason = line.Description;
            l.approvedBy = line.RLM_RTK_Approved_By__c;
            l.approvedAt = line.RLM_RTK_Approved_At__c;
            l.billed = line.RLM_RTK_Add_On_Order__c != null;
            state.lines.add(l);
            state.total += line.UnitPrice == null ? 0 : line.UnitPrice;
            addedSkus.add(l.sku);
        }

        Map<String, Suggestion> suggestions = suggest(wo.RLM_RTK_Inspection__c);
        for (PricebookEntry entry : entriesBySku().values()) {
            AddOn a = new AddOn();
            a.sku = entry.Product2.StockKeepingUnit;
            a.name = entry.Product2.Name;
            a.description = entry.Product2.Description;
            a.price = RLM_RTK_ZonePricing.apply(entry.UnitPrice, multiplier);
            a.added = addedSkus.contains(a.sku);
            Suggestion s = suggestions.get(a.sku);
            if (s != null) {
                a.recommended = true;
                a.reason = s.reason;
                a.findingId = s.findingId;
            }
            state.addOns.add(a);
        }
        state.addOns.sort(new RecommendedFirst());
        return state;
    }

    private class Suggestion {
        String reason;
        Id findingId;
        Suggestion(String reason, Id findingId) {
            this.reason = reason;
            this.findingId = findingId;
        }
    }

    /** Which add-ons the inspection's findings call for; the first finding that matches gives the reason. */
    @TestVisible
    private static Map<String, Suggestion> suggest(Id inspectionId) {
        Map<String, Suggestion> result = new Map<String, Suggestion>();
        if (inspectionId == null) {
            return result;
        }
        for (RLM_RTK_Finding__c f : [
            SELECT Id, Zone__c, Pest__c, Evidence__c FROM RLM_RTK_Finding__c
            WHERE Inspection__c = :inspectionId ORDER BY CreatedDate
        ]) {
            String place = f.Zone__c == null ? '' : ' in the ' + f.Zone__c.toLowerCase();
            if (f.Pest__c == 'Wasps / Bees') {
                put(result, WASP_NEST, 'Wasps / bees' + place + (f.Evidence__c == 'Nest' ? ' (nest)' : ''), f.Id);
            }
            if (f.Pest__c == 'Rodents' && (f.Evidence__c == 'Entry Point' || f.Evidence__c == 'Damage')) {
                put(result, RODENT_EXCLUSION, 'Rodent ' + f.Evidence__c.toLowerCase() + place, f.Id);
            }
            if (f.Zone__c == 'Attic' && (f.Evidence__c == 'Droppings' || f.Pest__c == 'Rodents')) {
                put(result, ATTIC_SANITATION, (f.Evidence__c == 'Droppings' ? 'Droppings' : 'Rodents') + place, f.Id);
            }
            if (f.Pest__c == 'Bed Bugs') {
                put(result, BED_BUG, 'Bed bugs' + place, f.Id);
            }
        }
        return result;
    }

    private static void put(Map<String, Suggestion> result, String sku, String reason, Id findingId) {
        if (!result.containsKey(sku)) {
            result.put(sku, new Suggestion(reason, findingId));
        }
    }

    private class RecommendedFirst implements Comparator<AddOn> {
        public Integer compare(AddOn a, AddOn b) {
            if (a.recommended != b.recommended) {
                return a.recommended ? -1 : 1;
            }
            return a.price == b.price ? 0 : (a.price < b.price ? -1 : 1);
        }
    }

    private static Map<String, PricebookEntry> entriesBySku() {
        Set<Id> productIds = new Set<Id>();
        for (ProductCategoryProduct pcp : [
            SELECT ProductId FROM ProductCategoryProduct WHERE ProductCategory.Code = :CATEGORY_CODE
        ]) {
            productIds.add(pcp.ProductId);
        }
        Id standardId = Test.isRunningTest()
            ? Test.getStandardPricebookId()
            : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        Map<String, PricebookEntry> entries = new Map<String, PricebookEntry>();
        for (PricebookEntry entry : [
            SELECT Id, UnitPrice, Pricebook2Id, Product2Id, Product2.StockKeepingUnit, Product2.Name, Product2.Description
            FROM PricebookEntry
            WHERE Product2Id IN :productIds AND Pricebook2Id = :standardId AND CurrencyIsoCode = 'USD'
                AND IsActive = true AND Product2.IsActive = true
        ]) {
            entries.put(entry.Product2.StockKeepingUnit, entry);
        }
        return entries;
    }

    private static List<WorkOrderLineItem> unbilledLines(Set<Id> workOrderIds) {
        return [
            SELECT Id, WorkOrderId, PricebookEntryId, PricebookEntry.Product2Id, UnitPrice
            FROM WorkOrderLineItem
            WHERE WorkOrderId IN :workOrderIds AND RLM_RTK_Approved_At__c != null
                AND RLM_RTK_Add_On_Order__c = null AND PricebookEntryId != null
        ];
    }

    private static WorkOrder workOrderFor(Id recordId) {
        if (recordId == null) {
            throw new AddOnException('Open this from a service appointment or work order.');
        }
        Id workOrderId = recordId;
        if (recordId.getSobjectType() == ServiceAppointment.SObjectType) {
            ServiceAppointment sa = [SELECT ParentRecordId FROM ServiceAppointment WHERE Id = :recordId];
            workOrderId = sa.ParentRecordId;
        }
        if (workOrderId == null || workOrderId.getSobjectType() != WorkOrder.SObjectType) {
            throw new AddOnException('Open this from a service appointment or work order.');
        }
        return [
            SELECT Id, WorkOrderNumber, Status, AccountId, Account.Name, Account.ShippingPostalCode, PostalCode,
                Contact.Name, Pricebook2Id, RLM_RTK_Inspection__c
            FROM WorkOrder WHERE Id = :workOrderId
        ];
    }

    private static AuraHandledException auraError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }

    public class AddOnException extends Exception {}
}

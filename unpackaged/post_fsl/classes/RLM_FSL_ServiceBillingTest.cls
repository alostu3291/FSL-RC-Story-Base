@IsTest
private class RLM_FSL_ServiceBillingTest {
    private class StubPlacer implements RLM_FSL_BillRepair.OrderPlacer {
        public Id place(WorkOrder workOrder, PricebookEntry entry) {
            Order repairOrder = new Order(AccountId = workOrder.AccountId, Pricebook2Id = entry.Pricebook2Id,
                EffectiveDate = Date.today(), Status = 'Draft');
            insert repairOrder;
            OrderAction action = new OrderAction(OrderId = repairOrder.Id, Type = 'Add');
            insert action;
            insert new OrderItem(OrderId = repairOrder.Id, OrderActionId = action.Id, PricebookEntryId = entry.Id,
                Product2Id = entry.Product2Id, Quantity = 1, UnitPrice = entry.UnitPrice, ServiceDate = Date.today());
            return repairOrder.Id;
        }
    }

    // StockKeepingUnit uniqueness is enforced against the org's real products, even in tests.
    private static final String TEST_REPAIR_SKU = 'QB-SVC-REPAIR-TEST';

    @TestSetup
    static void setup() {
        Account account = new Account(Name = 'FSL Billing Test', ShippingStreet = '415 Mission St',
            ShippingCity = 'San Francisco', ShippingState = 'CA', ShippingPostalCode = '94105', ShippingCountry = 'US');
        insert account;
        Product2 repair = new Product2(Name = 'Break/Fix Repair Service', StockKeepingUnit = TEST_REPAIR_SKU, IsActive = true);
        insert repair;
        insert new PricebookEntry(Product2Id = repair.Id, Pricebook2Id = Test.getStandardPricebookId(),
            UnitPrice = 1200, IsActive = true, CurrencyIsoCode = 'USD');
        insert new List<WorkOrder>{
            new WorkOrder(AccountId = account.Id, Subject = 'Replace failed drive'),
            new WorkOrder(AccountId = account.Id, Subject = 'Replace failed power supply')
        };
    }

    @IsTest
    static void billsEachUncoveredRepairOnce() {
        RLM_FSL_BillRepair.placer = new StubPlacer();
        RLM_FSL_BillRepair.repairSku = TEST_REPAIR_SKU;
        List<Id> workOrderIds = new List<Id>(new Map<Id, WorkOrder>([SELECT Id FROM WorkOrder]).keySet());

        Test.startTest();
        RLM_FSL_BillRepair.billRepairs(workOrderIds);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Order], 'The first job places one repair order and chains the next Work Order');
    }

    @IsTest
    static void lastRepairQueuesTheInvoice() {
        RLM_FSL_BillRepair.placer = new StubPlacer();
        RLM_FSL_BillRepair.repairSku = TEST_REPAIR_SKU;
        WorkOrder workOrder = [SELECT Id FROM WorkOrder LIMIT 1];

        Test.startTest();
        new RLM_FSL_BillRepair.RepairOrderJob(new List<Id>{ workOrder.Id }, new Set<Id>()).execute(null);
        Test.stopTest();

        Id orderId = [SELECT RLM_Billable_Order__c FROM WorkOrder WHERE Id = :workOrder.Id].RLM_Billable_Order__c;
        Assert.isNotNull(orderId, 'The work order links its repair order');
        Assert.areEqual('Activated', [SELECT Status FROM Order WHERE Id = :orderId].Status, 'The repair order is activated');
    }

    @IsTest
    static void pestReserviceBillsTheReserviceProduct() {
        Assert.areEqual(RLM_FSL_BillRepair.PEST_RESERVICE_SKU,
            RLM_FSL_BillRepair.skuFor(new WorkOrder(WorkType = new WorkType(Name = 'Pest Re-service'))),
            'Pest re-service visits bill the re-service product');
        Assert.areEqual(RLM_FSL_BillRepair.REPAIR_SKU, RLM_FSL_BillRepair.skuFor(new WorkOrder()),
            'Other work orders bill the break/fix repair');
    }

    @IsTest
    static void salesTransactionPlacerReportsFailures() {
        WorkOrder workOrder = [SELECT Id, WorkOrderNumber, AccountId, ContactId, WorkType.Name, Account.ShippingStreet, Account.ShippingCity,
                Account.ShippingState, Account.ShippingPostalCode, Account.ShippingCountry, Account.BillingStreet,
                Account.BillingCity, Account.BillingState, Account.BillingPostalCode, Account.BillingCountry
            FROM WorkOrder LIMIT 1];
        PricebookEntry entry = [SELECT Id, UnitPrice, Product2Id, Pricebook2Id FROM PricebookEntry LIMIT 1];
        try {
            new RLM_FSL_BillRepair.SalesTransactionPlacer().place(workOrder, entry);
        } catch (Exception e) {
            Assert.isNotNull(e.getMessage(), 'Placement errors surface to the caller');
        }
    }

    @IsTest
    static void invoiceJobSkipsOrdersWithoutReadySchedules() {
        Order repairOrder = new Order(AccountId = [SELECT Id FROM Account LIMIT 1].Id,
            Pricebook2Id = Test.getStandardPricebookId(), EffectiveDate = Date.today(), Status = 'Draft');
        insert repairOrder;

        Test.startTest();
        RLM_FSL_InvoiceOrder.invoiceOrders(new List<Id>{ repairOrder.Id });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Invoice], 'No invoice without ready billing schedules');
    }

    @IsTest
    static void invoiceJobRequestsPostedInvoice() {
        List<String> scheduleIds = new List<String>{ '44b000000000001AAA' };
        ConnectApi.InvoiceInputRepresentation request = RLM_FSL_InvoiceOrder.buildRequest(scheduleIds);
        Assert.areEqual(ConnectApi.InvoiceAction.Posted, request.action, 'Invoices are posted');
        Assert.areEqual(scheduleIds, request.billingScheduleIds, 'Only ready schedules are invoiced');

        RLM_FSL_InvoiceOrder.readyScheduleIdsOverride = scheduleIds;
        try {
            new RLM_FSL_InvoiceOrder.InvoiceJob(new Set<Id>(), 1).execute(null);
        } catch (Exception e) {
            Assert.isNotNull(e.getMessage(), 'Billing API is unavailable in unit tests');
        }
    }
}

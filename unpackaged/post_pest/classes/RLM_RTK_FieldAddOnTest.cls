@IsTest
private class RLM_RTK_FieldAddOnTest {
    private class StubPlacer implements RLM_RTK_FieldAddOn.OrderPlacer {
        public Id place(WorkOrder wo, List<WorkOrderLineItem> lines) {
            Order o = new Order(AccountId = wo.AccountId, Pricebook2Id = wo.Pricebook2Id,
                EffectiveDate = Date.today(), Status = 'Draft');
            insert o;
            return o.Id;
        }
    }

    private static final String SUFFIX = '-FATEST';

    static {
        RLM_RTK_FieldAddOn.skuSuffix = SUFFIX;
    }

    @TestSetup
    static void setup() {
        ProductCatalog catalog = new ProductCatalog(Name = 'Field Add-on Test', Code = 'CAT-RTK-TEST');
        insert catalog;
        ProductCategory category = new ProductCategory(Name = 'Field Add-ons', Code = RLM_RTK_FieldAddOn.CATEGORY_CODE,
            CatalogId = catalog.Id);
        insert category;
        List<Product2> products = new List<Product2>{
            new Product2(Name = 'Wasp & Hornet Nest Removal', StockKeepingUnit = RLM_RTK_FieldAddOn.WASP_NEST + SUFFIX, IsActive = true),
            new Product2(Name = 'Attic Sanitation', StockKeepingUnit = RLM_RTK_FieldAddOn.ATTIC_SANITATION + SUFFIX, IsActive = true)
        };
        insert products;
        List<PricebookEntry> entries = new List<PricebookEntry>();
        List<ProductCategoryProduct> links = new List<ProductCategoryProduct>();
        for (Product2 p : products) {
            entries.add(new PricebookEntry(Product2Id = p.Id, Pricebook2Id = Test.getStandardPricebookId(),
                UnitPrice = p.StockKeepingUnit == RLM_RTK_FieldAddOn.WASP_NEST + SUFFIX ? 179 : 499,
                IsActive = true, CurrencyIsoCode = 'USD'));
            links.add(new ProductCategoryProduct(ProductCategoryId = category.Id, ProductId = p.Id));
        }
        insert entries;
        insert links;

        Account account = new Account(Name = 'Add-on Test', ShippingPostalCode = '60108');
        insert account;
        RLM_RTK_Inspection__c inspection = new RLM_RTK_Inspection__c(Account__c = account.Id);
        insert inspection;
        insert new RLM_RTK_Finding__c(Inspection__c = inspection.Id, Zone__c = 'Yard', Pest__c = 'Wasps / Bees',
            Evidence__c = 'Nest', Severity__c = 'Moderate');
        insert new WorkOrder(AccountId = account.Id, Subject = 'Initial Pest Treatment',
            RLM_RTK_Inspection__c = inspection.Id);
    }

    private static WorkOrder workOrder() {
        return [SELECT Id, AccountId FROM WorkOrder LIMIT 1];
    }

    @IsTest
    static void findingsRecommendTheMatchingAddOn() {
        RLM_RTK_FieldAddOn.State state = RLM_RTK_FieldAddOn.getState(workOrder().Id);

        Assert.areEqual(2, state.addOns.size());
        RLM_RTK_FieldAddOn.AddOn first = state.addOns[0];
        Assert.areEqual(RLM_RTK_FieldAddOn.WASP_NEST, first.sku, 'Recommended add-ons come first');
        Assert.isTrue(first.recommended);
        Assert.areEqual('Wasps / bees in the yard (nest)', first.reason);
        Assert.isNotNull(first.findingId);
        Assert.isFalse(state.addOns[1].recommended);
        Assert.isNotNull(state.inspectionId);
    }

    @IsTest
    static void approvedAddOnsBecomeWorkOrderLinesOnce() {
        Id woId = workOrder().Id;
        List<String> skus = new List<String>{ RLM_RTK_FieldAddOn.WASP_NEST };

        RLM_RTK_FieldAddOn.addAddOns(woId, skus, 'Marcus Bell');
        RLM_RTK_FieldAddOn.State state = RLM_RTK_FieldAddOn.addAddOns(woId, skus, 'Marcus Bell');

        Assert.areEqual(1, state.lines.size(), 'Adding the same add-on again is ignored');
        Assert.areEqual('Marcus Bell', state.lines[0].approvedBy);
        Assert.areEqual(state.lines[0].price, state.total);
        WorkOrderLineItem line = [SELECT RLM_RTK_Finding__c, RLM_RTK_Approved_At__c FROM WorkOrderLineItem];
        Assert.isNotNull(line.RLM_RTK_Finding__c);
        Assert.isNotNull(line.RLM_RTK_Approved_At__c);

        state = RLM_RTK_FieldAddOn.removeAddOn(state.lines[0].id);
        Assert.areEqual(0, state.lines.size());
    }

    @IsTest
    static void approvalNeedsACustomerName() {
        try {
            RLM_RTK_FieldAddOn.addAddOns(workOrder().Id, new List<String>{ RLM_RTK_FieldAddOn.WASP_NEST }, ' ');
            Assert.fail('Expected an error without a customer name');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('customer'), e.getMessage());
        }
    }

    @IsTest
    static void completingTheVisitBillsApprovedAddOns() {
        RLM_RTK_FieldAddOn.placer = new StubPlacer();
        WorkOrder wo = workOrder();
        RLM_RTK_FieldAddOn.addAddOns(wo.Id, new List<String>{ RLM_RTK_FieldAddOn.ATTIC_SANITATION }, 'Marcus Bell');

        Test.startTest();
        RLM_RTK_FieldAddOn.billAddOns(new List<Id>{ wo.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Order WHERE AccountId = :wo.AccountId]);
    }

    @IsTest
    static void workOrdersWithoutAddOnsAreSkipped() {
        Test.startTest();
        RLM_RTK_FieldAddOn.billAddOns(new List<Id>{ workOrder().Id });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Order]);
    }

    private class StubGenerator implements RLM_RTK_AI.Generator {
        public String generate(String templateName, Map<String, Object> inputs) {
            return '{"suggestions":[{"sku":"' + RLM_RTK_FieldAddOn.ATTIC_SANITATION + '","reason":"Droppings noted in the attic"},'
                + '{"sku":"' + RLM_RTK_FieldAddOn.WASP_NEST + '","reason":"Already recommended"}]}';
        }
    }

    @IsTest
    static void einsteinSuggestsOnlyAddOnsTheRulesDidNot() {
        RLM_RTK_AI.generator = new StubGenerator();

        List<RLM_RTK_AI.Pick> picks = RLM_RTK_FieldAddOn.aiSuggestions(workOrder().Id);

        Assert.areEqual(1, picks.size(), 'The rules already recommend the wasp nest removal');
        Assert.areEqual(RLM_RTK_FieldAddOn.ATTIC_SANITATION, picks[0].sku);
        Assert.areEqual('Droppings noted in the attic', picks[0].reason);
    }
}

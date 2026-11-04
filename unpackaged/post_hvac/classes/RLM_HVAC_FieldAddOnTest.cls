@IsTest
private class RLM_HVAC_FieldAddOnTest {
    private class StubPlacer implements RLM_HVAC_FieldAddOn.OrderPlacer {
        public Id place(WorkOrder wo, List<WorkOrderLineItem> lines) {
            Order o = new Order(AccountId = wo.AccountId, Pricebook2Id = wo.Pricebook2Id,
                EffectiveDate = Date.today(), Status = 'Draft');
            insert o;
            return o.Id;
        }
    }

    private static final String SUFFIX = '-FATEST';

    static {
        RLM_HVAC_FieldAddOn.skuSuffix = SUFFIX;
    }

    @TestSetup
    static void setup() {
        ProductCatalog catalog = new ProductCatalog(Name = 'Field Add-on Test', Code = 'CAT-HVAC-TEST');
        insert catalog;
        ProductCategory category = new ProductCategory(Name = 'Field Add-ons', Code = RLM_HVAC_FieldAddOn.CATEGORY_CODE,
            CatalogId = catalog.Id);
        insert category;
        List<Product2> products = new List<Product2>{
            new Product2(Name = 'Capacitor Replacement', StockKeepingUnit = RLM_HVAC_Assessment.CAPACITOR + SUFFIX, IsActive = true),
            new Product2(Name = 'Blower Motor Replacement', StockKeepingUnit = RLM_HVAC_Assessment.BLOWER_MOTOR + SUFFIX, IsActive = true)
        };
        insert products;
        List<PricebookEntry> entries = new List<PricebookEntry>();
        List<ProductCategoryProduct> links = new List<ProductCategoryProduct>();
        for (Product2 p : products) {
            entries.add(new PricebookEntry(Product2Id = p.Id, Pricebook2Id = Test.getStandardPricebookId(),
                UnitPrice = p.StockKeepingUnit == RLM_HVAC_Assessment.CAPACITOR + SUFFIX ? 185 : 650,
                IsActive = true, CurrencyIsoCode = 'USD'));
            links.add(new ProductCategoryProduct(ProductCategoryId = category.Id, ProductId = p.Id));
        }
        insert entries;
        insert links;

        Account account = new Account(Name = 'Add-on Test', ShippingPostalCode = '60540');
        insert account;
        RLM_HVAC_Assessment__c assessment = new RLM_HVAC_Assessment__c(Account__c = account.Id);
        insert assessment;
        insert new RLM_HVAC_Finding__c(Assessment__c = assessment.Id, Equipment__c = 'Outdoor Unit', Component__c = 'Capacitor',
            Condition__c = 'Worn', Urgency__c = 'Repair Soon', Reading__c = '32 µF of 45');
        insert new WorkOrder(AccountId = account.Id, Subject = 'Spring AC Tune-up',
            RLM_HVAC_Assessment__c = assessment.Id);
    }

    private static WorkOrder workOrder() {
        return [SELECT Id, AccountId FROM WorkOrder LIMIT 1];
    }

    @IsTest
    static void findingsRecommendTheMatchingAddOn() {
        RLM_HVAC_FieldAddOn.State state = RLM_HVAC_FieldAddOn.getState(workOrder().Id);

        Assert.areEqual(2, state.addOns.size());
        RLM_HVAC_FieldAddOn.AddOn first = state.addOns[0];
        Assert.areEqual(RLM_HVAC_Assessment.CAPACITOR, first.sku, 'Recommended add-ons come first');
        Assert.isTrue(first.recommended);
        Assert.areEqual('Outdoor Unit: capacitor worn, 32 µF of 45 (repair soon)', first.reason);
        Assert.isNotNull(first.findingId);
        Assert.isFalse(state.addOns[1].recommended);
        Assert.isNotNull(state.assessmentId);
    }

    @IsTest
    static void approvedAddOnsBecomeWorkOrderLinesOnce() {
        Id woId = workOrder().Id;
        List<String> skus = new List<String>{ RLM_HVAC_Assessment.CAPACITOR };

        RLM_HVAC_FieldAddOn.addAddOns(woId, skus, 'Marcus Bell');
        RLM_HVAC_FieldAddOn.State state = RLM_HVAC_FieldAddOn.addAddOns(woId, skus, 'Marcus Bell');

        Assert.areEqual(1, state.lines.size(), 'Adding the same add-on again is ignored');
        Assert.areEqual('Marcus Bell', state.lines[0].approvedBy);
        Assert.areEqual(state.lines[0].price, state.total);
        WorkOrderLineItem line = [SELECT RLM_HVAC_Finding__c, RLM_HVAC_Approved_At__c FROM WorkOrderLineItem];
        Assert.isNotNull(line.RLM_HVAC_Finding__c);
        Assert.isNotNull(line.RLM_HVAC_Approved_At__c);

        state = RLM_HVAC_FieldAddOn.removeAddOn(state.lines[0].id);
        Assert.areEqual(0, state.lines.size());
    }

    @IsTest
    static void approvalNeedsACustomerName() {
        try {
            RLM_HVAC_FieldAddOn.addAddOns(workOrder().Id, new List<String>{ RLM_HVAC_Assessment.CAPACITOR }, ' ');
            Assert.fail('Expected an error without a customer name');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('customer'), e.getMessage());
        }
    }

    @IsTest
    static void completingTheVisitBillsApprovedAddOns() {
        RLM_HVAC_FieldAddOn.placer = new StubPlacer();
        WorkOrder wo = workOrder();
        RLM_HVAC_FieldAddOn.addAddOns(wo.Id, new List<String>{ RLM_HVAC_Assessment.BLOWER_MOTOR }, 'Marcus Bell');

        Test.startTest();
        RLM_HVAC_FieldAddOn.billAddOns(new List<Id>{ wo.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Order WHERE AccountId = :wo.AccountId]);
    }

    @IsTest
    static void workOrdersWithoutAddOnsAreSkipped() {
        Test.startTest();
        RLM_HVAC_FieldAddOn.billAddOns(new List<Id>{ workOrder().Id });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Order]);
    }

    private class StubGenerator implements RLM_HVAC_AI.Generator {
        public String generate(String templateName, Map<String, Object> inputs) {
            return '{"suggestions":[{"sku":"' + RLM_HVAC_Assessment.BLOWER_MOTOR + '","reason":"Blower motor bearings are loud at startup"},'
                + '{"sku":"' + RLM_HVAC_Assessment.CAPACITOR + '","reason":"Already recommended"}]}';
        }
    }

    @IsTest
    static void einsteinSuggestsOnlyAddOnsTheRulesDidNot() {
        RLM_HVAC_AI.generator = new StubGenerator();

        List<RLM_HVAC_AI.Pick> picks = RLM_HVAC_FieldAddOn.aiSuggestions(workOrder().Id);

        Assert.areEqual(1, picks.size(), 'The rules already recommend the capacitor');
        Assert.areEqual(RLM_HVAC_Assessment.BLOWER_MOTOR, picks[0].sku);
        Assert.areEqual('Blower motor bearings are loud at startup', picks[0].reason);
    }
}

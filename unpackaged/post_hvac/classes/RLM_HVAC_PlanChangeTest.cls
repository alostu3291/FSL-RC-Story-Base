@IsTest
private class RLM_HVAC_PlanChangeTest {
    private class StubPlacer implements RLM_HVAC_PlanChange.ChangePlacer {
        RLM_HVAC_PlanChange.Change placed;

        public Id place(RLM_HVAC_PlanChange.Change change) {
            placed = change;
            Order o = new Order(AccountId = change.accountId, Pricebook2Id = Test.getStandardPricebookId(),
                EffectiveDate = change.startDate, Status = 'Draft');
            insert o;
            OrderAction action = new OrderAction(OrderId = o.Id, Type = 'Add');
            insert action;
            PricebookEntry entry = [SELECT Id, Product2Id, UnitPrice FROM PricebookEntry LIMIT 1];
            insert new OrderItem(OrderId = o.Id, OrderActionId = action.Id, PricebookEntryId = entry.Id, Product2Id = entry.Product2Id,
                Quantity = 1, UnitPrice = entry.UnitPrice, ServiceDate = change.startDate);
            return o.Id;
        }
    }

    private static final String SUFFIX = '-PCTEST';

    static {
        RLM_HVAC_PlanChange.skuSuffix = SUFFIX;
    }

    private static final Map<String, Decimal> PRICES = new Map<String, Decimal>{
        RLM_HVAC_PlanChange.BASIC => 19, RLM_HVAC_PlanChange.PLUS => 29,
        RLM_HVAC_PlanChange.PREMIER => 45, RLM_HVAC_PlanChange.WATER_HEATER => 8,
        RLM_HVAC_PlanChange.IAQ => 15
    };

    @TestSetup
    static void setup() {
        List<Product2> products = new List<Product2>();
        for (String sku : PRICES.keySet()) {
            products.add(new Product2(Name = sku, StockKeepingUnit = sku + SUFFIX, IsActive = true));
        }
        insert products;
        List<PricebookEntry> entries = new List<PricebookEntry>();
        for (Product2 p : products) {
            entries.add(new PricebookEntry(Product2Id = p.Id, Pricebook2Id = Test.getStandardPricebookId(),
                UnitPrice = PRICES.get(p.StockKeepingUnit.removeEnd(SUFFIX)), IsActive = true, CurrencyIsoCode = 'USD'));
        }
        insert entries;

        Account account = new Account(Name = 'Agreement Change Test', ShippingPostalCode = '60540');
        insert account;
        insert new Contact(LastName = 'Bell', FirstName = 'Marcus', AccountId = account.Id);
        RLM_HVAC_Assessment__c assessment = new RLM_HVAC_Assessment__c(Account__c = account.Id);
        insert assessment;
        insert new List<RLM_HVAC_Finding__c>{
            new RLM_HVAC_Finding__c(Assessment__c = assessment.Id, Equipment__c = 'Outdoor Unit',
                Condition__c = 'Aging Equipment', Urgency__c = 'Monitor'),
            new RLM_HVAC_Finding__c(Assessment__c = assessment.Id, Equipment__c = 'Indoor Air',
                Condition__c = 'Allergies Noted', Urgency__c = 'Monitor')
        };
        insert new WorkOrder(AccountId = account.Id, Subject = 'Fall Furnace Tune-up',
            RLM_HVAC_Assessment__c = assessment.Id);
        hold(RLM_HVAC_PlanChange.BASIC, Date.today());
    }

    private static Id hold(String sku, Date startDate) {
        return hold(sku, startDate, PRICES.get(sku), 1);
    }

    /** An agreement asset; monthlyPrice is per unit (per system for a tier). */
    private static Id hold(String sku, Date startDate, Decimal monthlyPrice, Integer quantity) {
        Account account = [SELECT Id FROM Account LIMIT 1];
        Product2 product = [SELECT Id FROM Product2 WHERE StockKeepingUnit = :(sku + SUFFIX)];
        Asset asset = new Asset(Name = sku, AccountId = account.Id, Product2Id = product.Id);
        insert asset;
        insert new AssetStatePeriod(AssetId = asset.Id, StartDate = startDate, Quantity = quantity,
            Mrr = monthlyPrice * quantity, Amount = 0);
        return asset.Id;
    }

    private static Id workOrderId() {
        return [SELECT Id FROM WorkOrder LIMIT 1].Id;
    }

    private static RLM_HVAC_PlanChange.Plan plan(List<RLM_HVAC_PlanChange.Plan> plans, String sku) {
        for (RLM_HVAC_PlanChange.Plan p : plans) {
            if (p.sku == sku) {
                return p;
            }
        }
        return null;
    }

    @IsTest
    static void stateShowsTheCurrentAgreementAndWhatFindingsCallFor() {
        RLM_HVAC_PlanChange.State state = RLM_HVAC_PlanChange.getState(workOrderId());

        Assert.areEqual(RLM_HVAC_PlanChange.BASIC, state.currentPlanName);
        Assert.areEqual(19, state.monthlyTotal);
        Assert.areEqual(1, state.systemCount);
        Assert.areEqual(Date.today().addDays(1), state.startDate);
        Assert.isNull(state.lockedReason);
        Assert.areEqual(3, state.tiers.size());
        Assert.areEqual(2, state.addOnPlans.size());
        Assert.isTrue(plan(state.tiers, RLM_HVAC_PlanChange.BASIC).current);
        RLM_HVAC_PlanChange.Plan plus = plan(state.tiers, RLM_HVAC_PlanChange.PLUS);
        Assert.areEqual('Upgrade', plus.change);
        Assert.isTrue(plus.recommended);
        Assert.isTrue(plus.reason.startsWith('Aging equipment on the outdoor unit'), plus.reason);
        RLM_HVAC_PlanChange.Plan iaq = plan(state.addOnPlans, RLM_HVAC_PlanChange.IAQ);
        Assert.areEqual('Add', iaq.change);
        Assert.areEqual('Allergies noted in the home', iaq.reason);
        Assert.isFalse(plan(state.addOnPlans, RLM_HVAC_PlanChange.WATER_HEATER).recommended);
    }

    @IsTest
    static void upgradeReplacesTheCurrentAgreementFromTomorrow() {
        StubPlacer stub = new StubPlacer();
        RLM_HVAC_PlanChange.placer = stub;
        Id basicId = [SELECT Id FROM Asset WHERE Name = :RLM_HVAC_PlanChange.BASIC].Id;

        RLM_HVAC_PlanChange.State state = RLM_HVAC_PlanChange.applyChange(
            workOrderId(), RLM_HVAC_PlanChange.PLUS, 'Marcus Bell');

        Assert.areEqual(basicId, stub.placed.assetId);
        Assert.areEqual(-1, stub.placed.quantityChange);
        Assert.areEqual(1, stub.placed.quantity);
        Assert.areEqual('UpgradeFrom', stub.placed.fromSubtype);
        Assert.areEqual('UpgradeTo', stub.placed.toSubtype);
        Assert.areEqual(RLM_HVAC_PlanChange.PLUS + SUFFIX, stub.placed.entry.Product2.StockKeepingUnit);
        Assert.areEqual(Date.today().addDays(1), stub.placed.startDate);
        Order o = [SELECT Name, Description, BillToContactId FROM Order];
        Assert.isTrue(o.Name.startsWith('Agreement change: Upgrade'), o.Name);
        Assert.isTrue(o.Description.contains('Marcus Bell'), o.Description);
        Assert.isNotNull(o.BillToContactId);
        Assert.areEqual(1, state.scheduled.size());
        Assert.isNotNull(state.lockedReason, 'A scheduled change locks further changes');
    }

    @IsTest
    static void aTwoSystemHomeKeepsItsSystemCountOnUpgrade() {
        StubPlacer stub = new StubPlacer();
        RLM_HVAC_PlanChange.placer = stub;
        delete [SELECT Id FROM Asset];
        hold(RLM_HVAC_PlanChange.PLUS, Date.today(), 29, 2);

        RLM_HVAC_PlanChange.State state = RLM_HVAC_PlanChange.getState(workOrderId());
        Assert.areEqual(2, state.systemCount);
        Assert.areEqual(58, state.monthlyTotal);
        Assert.areEqual(32, plan(state.tiers, RLM_HVAC_PlanChange.PREMIER).monthlyChange, '$16 more for each of 2 systems');

        RLM_HVAC_PlanChange.applyChange(workOrderId(), RLM_HVAC_PlanChange.PREMIER, 'Marcus Bell');
        Assert.areEqual(-2, stub.placed.quantityChange);
        Assert.areEqual(2, stub.placed.quantity);
        Assert.areEqual(45, stub.placed.unitPrice);
        Assert.isTrue([SELECT Name FROM Order].Name.contains('(2 systems)'));
    }

    @IsTest
    static void theAgeAdjustmentCarriesToTheNewTier() {
        StubPlacer stub = new StubPlacer();
        RLM_HVAC_PlanChange.placer = stub;
        delete [SELECT Id FROM Asset];
        // Comfort Plus lists at $29; this home pays $35 because its equipment is 11–15 years old.
        hold(RLM_HVAC_PlanChange.PLUS, Date.today(), 35, 1);

        RLM_HVAC_PlanChange.State state = RLM_HVAC_PlanChange.getState(workOrderId());
        RLM_HVAC_PlanChange.Plan premier = plan(state.tiers, RLM_HVAC_PlanChange.PREMIER);
        Assert.areEqual(51, premier.price);
        Assert.areEqual(16, premier.monthlyChange);
        Assert.areEqual('Upgrade', premier.change);
        RLM_HVAC_PlanChange.Plan basic = plan(state.tiers, RLM_HVAC_PlanChange.BASIC);
        Assert.areEqual(25, basic.price);
        Assert.areEqual('Downgrade', basic.change);
        Assert.areEqual(PRICES.get(RLM_HVAC_PlanChange.WATER_HEATER), plan(state.addOnPlans, RLM_HVAC_PlanChange.WATER_HEATER).price,
            'Add-ons have no age adjustment');
        Assert.areEqual(6, state.adjustment);
        Assert.isNull(state.adjustmentReasons, 'No system check recorded what the adjustment is for');
        Assert.areEqual(45, premier.listPrice);
        Assert.areEqual(6, premier.adjustment);
        RLM_HVAC_PlanChange.Plan current = plan(state.tiers, RLM_HVAC_PlanChange.PLUS);
        Assert.areEqual(29, current.listPrice);
        Assert.areEqual(6, current.adjustment);

        update new RLM_HVAC_Assessment__c(Id = [SELECT Id FROM RLM_HVAC_Assessment__c LIMIT 1].Id,
            Equipment_Age__c = '11to15', Age_Adjustment__c = 6);
        state = RLM_HVAC_PlanChange.getState(workOrderId());
        Assert.areEqual('equipment 11–15 years old +$6', state.adjustmentReasons);

        RLM_HVAC_PlanChange.applyChange(workOrderId(), RLM_HVAC_PlanChange.PREMIER, 'Quinn Harper');
        Assert.areEqual(51, stub.placed.unitPrice);
    }

    @IsTest
    static void cheaperTierIsADowngrade() {
        StubPlacer stub = new StubPlacer();
        RLM_HVAC_PlanChange.placer = stub;
        delete [SELECT Id FROM Asset];
        hold(RLM_HVAC_PlanChange.PREMIER, Date.today());

        RLM_HVAC_PlanChange.applyChange(workOrderId(), RLM_HVAC_PlanChange.BASIC, 'Marcus Bell');

        Assert.areEqual('DowngradeFrom', stub.placed.fromSubtype);
        Assert.areEqual('DowngradeTo', stub.placed.toSubtype);
    }

    @IsTest
    static void addingAnAddOnAnchorsOnTheCurrentAgreement() {
        StubPlacer stub = new StubPlacer();
        RLM_HVAC_PlanChange.placer = stub;

        RLM_HVAC_PlanChange.applyChange(workOrderId(), RLM_HVAC_PlanChange.WATER_HEATER, 'Marcus Bell');

        Assert.areEqual([SELECT Id FROM Asset WHERE Name = :RLM_HVAC_PlanChange.BASIC].Id, stub.placed.assetId);
        Assert.areEqual(0, stub.placed.quantityChange);
        Assert.isNull(stub.placed.fromSubtype);
        Assert.areEqual(RLM_HVAC_PlanChange.WATER_HEATER + SUFFIX, stub.placed.entry.Product2.StockKeepingUnit);
    }

    @IsTest
    static void removingAnAddOnEndsItsAsset() {
        StubPlacer stub = new StubPlacer();
        RLM_HVAC_PlanChange.placer = stub;
        Id iaqId = hold(RLM_HVAC_PlanChange.IAQ, Date.today());

        RLM_HVAC_PlanChange.State before = RLM_HVAC_PlanChange.getState(workOrderId());
        Assert.areEqual('Remove', plan(before.addOnPlans, RLM_HVAC_PlanChange.IAQ).change);
        Assert.areEqual(34, before.monthlyTotal);

        RLM_HVAC_PlanChange.applyChange(workOrderId(), RLM_HVAC_PlanChange.IAQ, 'Marcus Bell');

        Assert.areEqual(iaqId, stub.placed.assetId);
        Assert.areEqual(-1, stub.placed.quantityChange);
        Assert.isNull(stub.placed.entry);
    }

    @IsTest
    static void changesNeedACustomerNameAndNoPendingChange() {
        RLM_HVAC_PlanChange.placer = new StubPlacer();
        try {
            RLM_HVAC_PlanChange.applyChange(workOrderId(), RLM_HVAC_PlanChange.WATER_HEATER, ' ');
            Assert.fail('Expected an error without a customer name');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('customer'), e.getMessage());
        }

        hold(RLM_HVAC_PlanChange.WATER_HEATER, Date.today().addDays(3));
        try {
            RLM_HVAC_PlanChange.applyChange(workOrderId(), RLM_HVAC_PlanChange.IAQ, 'Marcus Bell');
            Assert.fail('Expected an error while a change is pending');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('already scheduled'), e.getMessage());
        }
    }

    private class StubGenerator implements RLM_HVAC_AI.Generator {
        public String generate(String templateName, Map<String, Object> inputs) {
            return '{"suggestions":[{"sku":"' + RLM_HVAC_PlanChange.WATER_HEATER + '","reason":"Water heater is 12 years old"},'
                + '{"sku":"' + RLM_HVAC_PlanChange.BASIC + '","reason":"Current agreement"}]}';
        }
    }

    @IsTest
    static void einsteinSuggestsOnlyAgreementsTheCustomerCouldAdd() {
        RLM_HVAC_AI.generator = new StubGenerator();

        List<RLM_HVAC_AI.Pick> picks = RLM_HVAC_PlanChange.aiSuggestions(workOrderId());

        Assert.areEqual(1, picks.size(), 'The current agreement is never suggested');
        Assert.areEqual(RLM_HVAC_PlanChange.WATER_HEATER, picks[0].sku);
    }
}

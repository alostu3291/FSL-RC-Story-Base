@IsTest
private class RLM_RTK_PlanChangeTest {
    private class StubPlacer implements RLM_RTK_PlanChange.ChangePlacer {
        RLM_RTK_PlanChange.Change placed;

        public Id place(RLM_RTK_PlanChange.Change change) {
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
        RLM_RTK_PlanChange.skuSuffix = SUFFIX;
    }

    private static final Map<String, Decimal> PRICES = new Map<String, Decimal>{
        RLM_RTK_PlanChange.ESSENTIAL => 45, RLM_RTK_PlanChange.HOME_PROTECTION => 59,
        RLM_RTK_PlanChange.HOME_PROTECTION_PLUS => 79, RLM_RTK_PlanChange.TERMITE => 39,
        RLM_RTK_PlanChange.MOSQUITO => 69
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

        Account account = new Account(Name = 'Plan Change Test', ShippingPostalCode = '60108');
        insert account;
        insert new Contact(LastName = 'Bell', FirstName = 'Marcus', AccountId = account.Id);
        RLM_RTK_Inspection__c inspection = new RLM_RTK_Inspection__c(Account__c = account.Id);
        insert inspection;
        insert new List<RLM_RTK_Finding__c>{
            new RLM_RTK_Finding__c(Inspection__c = inspection.Id, Zone__c = 'Attic', Pest__c = 'Rodents',
                Evidence__c = 'Droppings', Severity__c = 'Moderate'),
            new RLM_RTK_Finding__c(Inspection__c = inspection.Id, Zone__c = 'Yard', Pest__c = 'Other',
                Evidence__c = 'Standing Water', Severity__c = 'Light')
        };
        insert new WorkOrder(AccountId = account.Id, Subject = 'Quarterly Pest Service',
            RLM_RTK_Inspection__c = inspection.Id);
        hold(RLM_RTK_PlanChange.ESSENTIAL, Date.today());
    }

    private static Id hold(String sku, Date startDate) {
        Account account = [SELECT Id FROM Account LIMIT 1];
        Product2 product = [SELECT Id FROM Product2 WHERE StockKeepingUnit = :(sku + SUFFIX)];
        Asset asset = new Asset(Name = sku, AccountId = account.Id, Product2Id = product.Id);
        insert asset;
        insert new AssetStatePeriod(AssetId = asset.Id, StartDate = startDate, Quantity = 1, Mrr = PRICES.get(sku), Amount = 0);
        return asset.Id;
    }

    private static Id workOrderId() {
        return [SELECT Id FROM WorkOrder LIMIT 1].Id;
    }

    private static RLM_RTK_PlanChange.Plan plan(List<RLM_RTK_PlanChange.Plan> plans, String sku) {
        for (RLM_RTK_PlanChange.Plan p : plans) {
            if (p.sku == sku) {
                return p;
            }
        }
        return null;
    }

    @IsTest
    static void stateShowsTheCurrentPlanAndWhatFindingsCallFor() {
        RLM_RTK_PlanChange.State state = RLM_RTK_PlanChange.getState(workOrderId());

        Assert.areEqual(RLM_RTK_PlanChange.ESSENTIAL, state.currentPlanName);
        Assert.areEqual(45, state.monthlyTotal);
        Assert.areEqual(Date.today().addDays(1), state.startDate);
        Assert.isNull(state.lockedReason);
        Assert.areEqual(3, state.tiers.size());
        Assert.areEqual(2, state.addOnPlans.size());
        Assert.isTrue(plan(state.tiers, RLM_RTK_PlanChange.ESSENTIAL).current);
        RLM_RTK_PlanChange.Plan homeProtection = plan(state.tiers, RLM_RTK_PlanChange.HOME_PROTECTION);
        Assert.areEqual('Upgrade', homeProtection.change);
        Assert.isTrue(homeProtection.recommended);
        Assert.isTrue(homeProtection.reason.startsWith('Rodents in the attic'), homeProtection.reason);
        RLM_RTK_PlanChange.Plan mosquito = plan(state.addOnPlans, RLM_RTK_PlanChange.MOSQUITO);
        Assert.areEqual('Add', mosquito.change);
        Assert.areEqual('Standing water in the yard', mosquito.reason);
        Assert.isFalse(plan(state.addOnPlans, RLM_RTK_PlanChange.TERMITE).recommended);
    }

    @IsTest
    static void upgradeReplacesTheCurrentPlanFromTomorrow() {
        StubPlacer stub = new StubPlacer();
        RLM_RTK_PlanChange.placer = stub;
        Id essentialId = [SELECT Id FROM Asset WHERE Name = :RLM_RTK_PlanChange.ESSENTIAL].Id;

        RLM_RTK_PlanChange.State state = RLM_RTK_PlanChange.applyChange(
            workOrderId(), RLM_RTK_PlanChange.HOME_PROTECTION, 'Marcus Bell');

        Assert.areEqual(essentialId, stub.placed.assetId);
        Assert.areEqual(-1, stub.placed.quantityChange);
        Assert.areEqual('UpgradeFrom', stub.placed.fromSubtype);
        Assert.areEqual('UpgradeTo', stub.placed.toSubtype);
        Assert.areEqual(RLM_RTK_PlanChange.HOME_PROTECTION + SUFFIX, stub.placed.entry.Product2.StockKeepingUnit);
        Assert.areEqual(Date.today().addDays(1), stub.placed.startDate);
        Order o = [SELECT Name, Description, BillToContactId FROM Order];
        Assert.isTrue(o.Name.startsWith('Plan change: Upgrade'), o.Name);
        Assert.isTrue(o.Description.contains('Marcus Bell'), o.Description);
        Assert.isNotNull(o.BillToContactId);
        Assert.areEqual(1, state.scheduled.size());
        Assert.isNotNull(state.lockedReason, 'A scheduled change locks further changes');
    }

    @IsTest
    static void cheaperTierIsADowngrade() {
        StubPlacer stub = new StubPlacer();
        RLM_RTK_PlanChange.placer = stub;
        delete [SELECT Id FROM Asset];
        hold(RLM_RTK_PlanChange.HOME_PROTECTION_PLUS, Date.today());

        RLM_RTK_PlanChange.applyChange(workOrderId(), RLM_RTK_PlanChange.ESSENTIAL, 'Marcus Bell');

        Assert.areEqual('DowngradeFrom', stub.placed.fromSubtype);
        Assert.areEqual('DowngradeTo', stub.placed.toSubtype);
    }

    @IsTest
    static void addingAPlanAnchorsOnTheCurrentPlan() {
        StubPlacer stub = new StubPlacer();
        RLM_RTK_PlanChange.placer = stub;

        RLM_RTK_PlanChange.applyChange(workOrderId(), RLM_RTK_PlanChange.TERMITE, 'Marcus Bell');

        Assert.areEqual([SELECT Id FROM Asset WHERE Name = :RLM_RTK_PlanChange.ESSENTIAL].Id, stub.placed.assetId);
        Assert.areEqual(0, stub.placed.quantityChange);
        Assert.isNull(stub.placed.fromSubtype);
        Assert.areEqual(RLM_RTK_PlanChange.TERMITE + SUFFIX, stub.placed.entry.Product2.StockKeepingUnit);
    }

    @IsTest
    static void removingAnAddOnPlanEndsItsAsset() {
        StubPlacer stub = new StubPlacer();
        RLM_RTK_PlanChange.placer = stub;
        Id mosquitoId = hold(RLM_RTK_PlanChange.MOSQUITO, Date.today());

        RLM_RTK_PlanChange.State before = RLM_RTK_PlanChange.getState(workOrderId());
        Assert.areEqual('Remove', plan(before.addOnPlans, RLM_RTK_PlanChange.MOSQUITO).change);
        Assert.areEqual(114, before.monthlyTotal);

        RLM_RTK_PlanChange.applyChange(workOrderId(), RLM_RTK_PlanChange.MOSQUITO, 'Marcus Bell');

        Assert.areEqual(mosquitoId, stub.placed.assetId);
        Assert.areEqual(-1, stub.placed.quantityChange);
        Assert.isNull(stub.placed.entry);
    }

    @IsTest
    static void changesNeedACustomerNameAndNoPendingChange() {
        RLM_RTK_PlanChange.placer = new StubPlacer();
        try {
            RLM_RTK_PlanChange.applyChange(workOrderId(), RLM_RTK_PlanChange.TERMITE, ' ');
            Assert.fail('Expected an error without a customer name');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('customer'), e.getMessage());
        }

        hold(RLM_RTK_PlanChange.TERMITE, Date.today().addDays(3));
        try {
            RLM_RTK_PlanChange.applyChange(workOrderId(), RLM_RTK_PlanChange.MOSQUITO, 'Marcus Bell');
            Assert.fail('Expected an error while a change is pending');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('already scheduled'), e.getMessage());
        }
    }

    private class StubGenerator implements RLM_RTK_AI.Generator {
        public String generate(String templateName, Map<String, Object> inputs) {
            return '{"suggestions":[{"sku":"' + RLM_RTK_PlanChange.TERMITE + '","reason":"Mud tubes on the garage wall"},'
                + '{"sku":"' + RLM_RTK_PlanChange.ESSENTIAL + '","reason":"Current plan"}]}';
        }
    }

    @IsTest
    static void einsteinSuggestsOnlyPlansTheCustomerCouldAdd() {
        RLM_RTK_AI.generator = new StubGenerator();

        List<RLM_RTK_AI.Pick> picks = RLM_RTK_PlanChange.aiSuggestions(workOrderId());

        Assert.areEqual(1, picks.size(), 'The current plan is never suggested');
        Assert.areEqual(RLM_RTK_PlanChange.TERMITE, picks[0].sku);
    }
}

@IsTest
private class RLM_HVAC_CapitalProjectTest {
    private class Fixture {
        Account parent;
        Account office;
        Account bistro;
        Map<String, Asset> officeUnits = new Map<String, Asset>();
    }

    private static Fixture fixture() {
        Integer thisYear = Date.today().year();
        Fixture f = new Fixture();
        f.parent = new Account(Name = 'Project Test Group', RLM_HVAC_Site_Type__c = 'Headquarters');
        insert f.parent;
        f.office = new Account(Name = 'Project Test Office', ParentId = f.parent.Id, RLM_HVAC_Site_Type__c = 'Office',
            RLM_HVAC_Site_Code__c = 'PT-1');
        f.bistro = new Account(Name = 'Project Test Bistro', ParentId = f.parent.Id, RLM_HVAC_Site_Type__c = 'Restaurant',
            RLM_HVAC_Site_Code__c = 'PT-2');
        insert new List<Account>{ f.office, f.bistro };
        f.officeUnits.put('RTU-01', unit(f.office, 'RTU-01', 10, thisYear - 19, 'R-22'));
        f.officeUnits.put('RTU-02', unit(f.office, 'RTU-02', 10, thisYear - 16, 'R-410A'));
        f.officeUnits.put('RTU-03', unit(f.office, 'RTU-03', 10, thisYear - 4, 'R-410A'));
        f.officeUnits.put('RTU-04', unit(f.office, 'RTU-04', 15, thisYear - 20, 'R-22'));
        List<Asset> units = new List<Asset>(f.officeUnits.values());
        units.add(unit(f.bistro, 'RTU-01', 10, thisYear - 3, 'R-454B'));
        insert units;
        RLM_HVAC_CapitalProject.testPrices = new Map<String, Decimal>{
            RLM_HVAC_CapitalProject.REPLACEMENT_SKU => 16800, RLM_HVAC_CapitalProject.CRANE_SKU => 2600
        };
        return f;
    }

    private static Asset unit(Account site, String tag, Decimal tons, Integer installYear, String refrigerant) {
        return new Asset(Name = tag, AccountId = site.Id, RLM_HVAC_Unit_Tag__c = tag, RLM_HVAC_Tonnage__c = tons,
            RLM_HVAC_Install_Year__c = installYear, RLM_HVAC_Refrigerant_Type__c = refrigerant, RLM_HVAC_Refrigerant_Charge__c = 24);
    }

    @IsTest
    static void theProposalOpensOnTheSiteWithTheMostUnitsDue() {
        Fixture f = fixture();

        RLM_HVAC_CapitalProject.Proposal p = RLM_HVAC_CapitalProject.proposal(f.parent.Id, null);

        Assert.areEqual(f.parent.Id, p.groupId);
        Assert.areEqual(f.office.Id, p.siteId, 'the office has two units due, the bistro none');
        Assert.areEqual(2, p.sites.size());
        Assert.areEqual(16800, p.unitPrice);
        Assert.areEqual(2600, p.cranePrice);
        Assert.areEqual(4, p.units.size());
        Map<String, RLM_HVAC_CapitalProject.Unit> byTag = new Map<String, RLM_HVAC_CapitalProject.Unit>();
        for (RLM_HVAC_CapitalProject.Unit u : p.units) {
            byTag.put(u.tag, u);
        }
        Assert.isTrue(byTag.get('RTU-01').recommended);
        Assert.isTrue(byTag.get('RTU-01').reason.contains('R-22 is phased out'), byTag.get('RTU-01').reason);
        Assert.isTrue(byTag.get('RTU-02').recommended, 'a 16-year-old unit is due by age');
        Assert.isFalse(byTag.get('RTU-03').recommended);
        Assert.isTrue(byTag.get('RTU-03').eligible);
        Assert.isFalse(byTag.get('RTU-04').eligible, 'only 10-ton replacements are priced');
        Assert.isFalse(byTag.get('RTU-04').recommended);
        List<Integer> percents = new List<Integer>();
        for (RLM_HVAC_CapitalProject.Milestone m : p.milestones) {
            percents.add(m.percent.intValue());
        }
        Assert.areEqual(new List<Integer>{ 40, 40, 20 }, percents);
        Assert.isNull(p.openQuoteId);
    }

    @IsTest
    static void theProposalOpensOnTheSiteItIsLaunchedFrom() {
        Fixture f = fixture();

        RLM_HVAC_CapitalProject.Proposal fromSite = RLM_HVAC_CapitalProject.proposal(f.bistro.Id, null);
        RLM_HVAC_CapitalProject.Proposal picked = RLM_HVAC_CapitalProject.proposal(f.parent.Id, f.bistro.Id);

        Assert.areEqual(f.parent.Id, fromSite.groupId, 'a site resolves to its property group');
        Assert.areEqual(f.bistro.Id, fromSite.siteId);
        Assert.areEqual(f.bistro.Id, picked.siteId);
        Assert.areEqual(1, picked.units.size());
    }

    @IsTest
    static void aProjectQuoteNeedsEligibleUnits() {
        Fixture f = fixture();
        try {
            RLM_HVAC_CapitalProject.createQuote(f.office.Id, new List<Id>{ f.officeUnits.get('RTU-04').Id });
            Assert.fail('a 15-ton unit has no replacement price');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('No replacement priced for 15 tons'), e.getMessage());
        }
        try {
            RLM_HVAC_CapitalProject.createQuote(f.office.Id, new List<Id>());
            Assert.fail('a project replaces at least one unit');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Pick the units'), e.getMessage());
        }
    }

    @IsTest
    static void unitTagsComeFromTheOrderLineDescription() {
        Assert.areEqual(new List<String>{ 'RTU-01', 'RTU-02', 'RTU-06' },
            RLM_HVAC_CapitalProject.tagsOf('RTU-01, RTU-02,RTU-06, '));
        Assert.areEqual(new List<String>(), RLM_HVAC_CapitalProject.tagsOf(null));
    }

    @IsTest
    static void aCompletedWorkOrderOutsideAProjectChangesNothing() {
        Fixture f = fixture();
        WorkOrder wo = new WorkOrder(AccountId = f.office.Id, Subject = 'Quarterly visit');
        insert wo;
        insert new WorkOrderLineItem(WorkOrderId = wo.Id, AssetId = f.officeUnits.get('RTU-01').Id);

        wo.Status = 'Completed';
        update wo;

        Asset unit = [SELECT RLM_HVAC_Refrigerant_Type__c FROM Asset WHERE Id = :f.officeUnits.get('RTU-01').Id];
        Assert.areEqual('R-22', unit.RLM_HVAC_Refrigerant_Type__c);
    }
}

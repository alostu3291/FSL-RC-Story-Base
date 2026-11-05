@IsTest
private class RLM_HVAC_ContractQuoteTest {

    private static final Map<String, Decimal> PRICES = new Map<String, Decimal>{
        'HVAC-COM-PM-S' => 38, 'HVAC-COM-PM-M' => 55, 'HVAC-COM-PM-L' => 85, 'HVAC-COM-PM-XL' => 130,
        'HVAC-COM-FILTER' => 9, 'HVAC-COM-RESP-4H' => 175, 'HVAC-COM-RESP-NBD' => 45
    };

    private static Map<String, String> names() {
        Map<String, String> out = new Map<String, String>();
        for (String sku : PRICES.keySet()) {
            out.put(sku, sku);
        }
        return out;
    }

    private static Asset unit(Id accountId, String tag, Decimal tons, Integer year, Decimal charge) {
        return new Asset(AccountId = accountId, Name = tag, RLM_HVAC_Unit_Tag__c = tag, RLM_HVAC_Tonnage__c = tons,
            RLM_HVAC_Install_Year__c = year, RLM_HVAC_Refrigerant_Charge__c = charge, Status = 'Installed');
    }

    @IsTest
    static void tonnageSetsTheMaintenanceBand() {
        Assert.areEqual('HVAC-COM-PM-S', RLM_HVAC_CommercialPricing.bandSku(5));
        Assert.areEqual('HVAC-COM-PM-M', RLM_HVAC_CommercialPricing.bandSku(7.5));
        Assert.areEqual('HVAC-COM-PM-M', RLM_HVAC_CommercialPricing.bandSku(12));
        Assert.areEqual('HVAC-COM-PM-L', RLM_HVAC_CommercialPricing.bandSku(12.5));
        Assert.areEqual('HVAC-COM-PM-L', RLM_HVAC_CommercialPricing.bandSku(25));
        Assert.areEqual('HVAC-COM-PM-XL', RLM_HVAC_CommercialPricing.bandSku(30));
    }

    @IsTest
    static void siteTypeSetsTheResponse() {
        Assert.areEqual('HVAC-COM-RESP-4H', RLM_HVAC_CommercialPricing.responseSku('Restaurant'));
        Assert.areEqual('HVAC-COM-RESP-4H', RLM_HVAC_CommercialPricing.responseSku('Data Room'));
        Assert.areEqual('HVAC-COM-RESP-NBD', RLM_HVAC_CommercialPricing.responseSku('Office'));
        Assert.isNull(RLM_HVAC_CommercialPricing.responseSku('Headquarters'));
        Assert.areEqual(4, RLM_HVAC_CommercialPricing.responseHours('HVAC-COM-RESP-4H'));
        Assert.areEqual(24, RLM_HVAC_CommercialPricing.responseHours('HVAC-COM-RESP-NBD'));
    }

    @IsTest
    static void discountsAndRenewal() {
        Assert.isFalse(RLM_HVAC_CommercialPricing.needsApproval(10));
        Assert.isTrue(RLM_HVAC_CommercialPricing.needsApproval(15));
        Assert.areEqual(52.25, RLM_HVAC_CommercialPricing.discounted(55, 5));
        Assert.areEqual(55, RLM_HVAC_CommercialPricing.discounted(55, null));
        Assert.isFalse(RLM_HVAC_CommercialPricing.isDiscountable('HVAC-COM-RESP-4H'));
        Assert.areEqual(56.65, RLM_HVAC_CommercialPricing.renewalPrice(55));
        Assert.areEqual(Date.newInstance(2026, 12, 1), RLM_HVAC_CommercialPricing.defaultStart(Date.newInstance(2026, 11, 4)));
        Assert.areEqual(Date.newInstance(2027, 11, 30), RLM_HVAC_CommercialPricing.endFor(Date.newInstance(2026, 12, 1)));
    }

    @IsTest
    static void planGroupsUnitsBySiteAndBand() {
        Account hq = new Account(Name = 'HQ', RLM_HVAC_Site_Type__c = 'Headquarters');
        insert hq;
        Account office = new Account(Name = 'Office', ParentId = hq.Id, RLM_HVAC_Site_Type__c = 'Office');
        Account bistro = new Account(Name = 'Bistro', ParentId = hq.Id, RLM_HVAC_Site_Type__c = 'Restaurant');
        insert new List<Account>{ office, bistro };
        List<Asset> units = new List<Asset>{
            unit(office.Id, 'RTU-01', 10, 2008, 24), unit(office.Id, 'RTU-02', 10, 2016, 24),
            unit(office.Id, 'RTU-03', 30, 2016, 62), unit(bistro.Id, 'RTU-01', 5, 2017, 11)
        };
        insert units;
        Formula.recalculateFormulas(units);

        RLM_HVAC_ContractQuote.Plan plan = RLM_HVAC_ContractQuote.buildPlan(
            new List<Account>{ hq, office, bistro }, units, PRICES, names(), true, 10);

        Assert.areEqual(2, plan.sites.size(), 'HQ has no units, so it gets no group');
        RLM_HVAC_ContractQuote.Site o = plan.sites[0];
        Assert.areEqual(3, o.unitCount);
        Assert.areEqual(50, o.tons);
        Assert.areEqual(1, o.trackedUnits);
        Assert.areEqual(2008, o.oldestYear);
        Assert.areEqual(4, o.lines.size(), 'two bands, filters, response');
        Assert.areEqual('HVAC-COM-PM-M', o.lines[0].sku);
        Assert.areEqual(2, o.lines[0].quantity);
        Assert.areEqual('RTU-01, RTU-02', o.lines[0].units);
        Assert.areEqual(49.50, o.lines[0].unitPrice);
        Assert.areEqual('HVAC-COM-RESP-NBD', o.lines[3].sku);
        Assert.areEqual(45, o.lines[3].unitPrice, 'response coverage is not discounted');
        // 2 x 49.50 + 117.00 + 3 x 8.10 + 45 = 285.30
        Assert.areEqual(285.30, o.monthly);
        Assert.areEqual('HVAC-COM-RESP-4H', plan.sites[1].lines[2].sku);
        Assert.areEqual(4, plan.unitCount);
        Assert.areEqual(plan.monthly * 12, plan.annual);
        Assert.isFalse(plan.needsApproval);
    }

    @IsTest
    static void noFilterProgramAndApproval() {
        Account site = new Account(Name = 'Office', RLM_HVAC_Site_Type__c = 'Office');
        insert site;
        List<Asset> units = new List<Asset>{ unit(site.Id, 'RTU-01', 4, 2020, 9) };
        insert units;
        RLM_HVAC_ContractQuote.Plan plan = RLM_HVAC_ContractQuote.buildPlan(
            new List<Account>{ site }, units, PRICES, names(), false, 18);
        Assert.areEqual(2, plan.sites[0].lines.size());
        Assert.isTrue(plan.needsApproval);
    }

    @IsTest
    static void previewReadsTheOrg() {
        Account hq = new Account(Name = 'HQ');
        insert hq;
        Account office = new Account(Name = 'Office', ParentId = hq.Id, RLM_HVAC_Site_Type__c = 'Office');
        insert office;
        insert new Contact(AccountId = hq.Id, LastName = 'Castillo', Title = 'Director of Facilities');
        insert unit(office.Id, 'RTU-01', 10, 2015, 24);
        try {
            RLM_HVAC_ContractQuote.Plan plan = RLM_HVAC_ContractQuote.preview(hq.Id, true, 0);
            Assert.areEqual(1, plan.sites.size());
            Assert.areEqual('Castillo', plan.contactName);
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Missing a price'), e.getMessage());
        }
    }
}

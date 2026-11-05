@IsTest
private class RLM_HVAC_ContractChangeTest {
    // Product SKUs are unique org-wide, including the real catalog, so the tests use their own.
    private static final String RESPONSE_SKU = 'HVAC-COM-RESP-4H-CHGTEST';

    private class Fixture {
        Account parent;
        Account covered;
        Account open;
        Asset contractAsset;
    }

    private static Fixture fixture() {
        Fixture f = new Fixture();
        insert new WorkType(Name = RLM_HVAC_CommercialCoverage.MAINTENANCE_WORK_TYPE, EstimatedDuration = 4,
            DurationType = 'Hours', ShouldAutoCreateSvcAppt = false);
        f.parent = new Account(Name = 'Change Test Group', RLM_HVAC_Site_Type__c = 'Headquarters');
        insert f.parent;
        insert new Contact(AccountId = f.parent.Id, LastName = 'Director', Title = 'Director of Facilities');
        f.covered = new Account(Name = 'Change Test Bistro', ParentId = f.parent.Id, RLM_HVAC_Site_Type__c = 'Restaurant',
            RLM_HVAC_Site_Code__c = 'CT-1');
        f.open = new Account(Name = 'Change Test Office', ParentId = f.parent.Id, RLM_HVAC_Site_Type__c = 'Office',
            RLM_HVAC_Site_Code__c = 'CT-2');
        insert new List<Account>{ f.covered, f.open };
        insert new List<Asset>{
            new Asset(Name = 'RTU-01', AccountId = f.covered.Id, RLM_HVAC_Unit_Tag__c = 'RTU-01', RLM_HVAC_Tonnage__c = 5),
            new Asset(Name = 'RTU-01', AccountId = f.open.Id, RLM_HVAC_Unit_Tag__c = 'RTU-01', RLM_HVAC_Tonnage__c = 10),
            new Asset(Name = 'RTU-02', AccountId = f.open.Id, RLM_HVAC_Unit_Tag__c = 'RTU-02', RLM_HVAC_Tonnage__c = 15)
        };
        Product2 response = new Product2(Name = '4-Hour Response', StockKeepingUnit = RESPONSE_SKU, IsActive = true);
        insert response;
        f.contractAsset = new Asset(Name = '4-Hour Response', AccountId = f.parent.Id, Product2Id = response.Id,
            RLM_HVAC_Site__c = f.covered.Id,
            LifecycleStartDate = Datetime.newInstanceGmt(Date.today().addMonths(-2), Time.newInstance(0, 0, 0, 0)),
            LifecycleEndDate = Datetime.newInstanceGmt(Date.today().addMonths(10), Time.newInstance(0, 0, 0, 0)));
        insert f.contractAsset;
        RLM_HVAC_Coverage.SITE_RESPONSE.put(RESPONSE_SKU, RLM_HVAC_Coverage.SITE_RESPONSE.get('HVAC-COM-RESP-4H'));
        RLM_HVAC_ContractQuote.testPrices = new Map<String, Decimal>{
            'HVAC-COM-PM-S' => 38, 'HVAC-COM-PM-M' => 55, 'HVAC-COM-PM-L' => 85, 'HVAC-COM-PM-XL' => 130,
            'HVAC-COM-FILTER' => 9, 'HVAC-COM-RESP-4H' => 175, 'HVAC-COM-RESP-NBD' => 45
        };
        return f;
    }

    @IsTest
    static void addingASiteOffersTheGroupsUncoveredSites() {
        Fixture f = fixture();

        RLM_HVAC_ContractAmend.State s = RLM_HVAC_ContractAmend.state(f.covered.Id);

        Assert.isTrue(s.hasContract);
        Assert.areEqual(f.parent.Id, s.groupId, 'a site resolves to its property group');
        Assert.areEqual(1, s.coveredSites);
        Assert.areEqual(Date.today().addMonths(10), s.contractEnd);
        Assert.areEqual(Date.today().toStartOfMonth().addMonths(1), s.effectiveDate);
        Assert.areEqual(1, s.candidates.size());
        Assert.areEqual(f.open.Id, s.candidates[0].accountId);
        Assert.areEqual(2, s.candidates[0].site.unitCount);
        // 10 tons (55) + 15 tons (85) + 2 filters (9) + next-business-day response (45)
        Assert.areEqual(203, s.candidates[0].site.monthly);
    }

    @IsTest
    static void aSiteIsAddedOnlyWithinTheContract() {
        Fixture f = fixture();
        try {
            RLM_HVAC_ContractAmend.addSite(f.open.Id, String.valueOf(Date.today().addYears(2)));
            Assert.fail('the amendment co-terminates with the contract');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('before the contract ends'), e.getMessage());
        }
        try {
            RLM_HVAC_ContractAmend.addSite(f.covered.Id, null);
            Assert.fail('a covered site is already on the contract');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('already on the contract'), e.getMessage());
        }
    }

    @IsTest
    static void theAmendmentStartsNextMonthOrAMonthIntoTheContract() {
        Date contractStart = Date.newInstance(2026, 12, 1);
        Assert.areEqual(Date.newInstance(2027, 1, 1),
            RLM_HVAC_ContractAmend.defaultEffectiveDate(Date.newInstance(2026, 11, 4), contractStart));
        Assert.areEqual(Date.newInstance(2027, 4, 1),
            RLM_HVAC_ContractAmend.defaultEffectiveDate(Date.newInstance(2027, 3, 15), contractStart));
    }

    @IsTest
    static void renewalAddsTheAnnualIncrease() {
        Assert.areEqual(103, RLM_HVAC_ContractRenew.renewalPrice(100));
        Assert.areEqual(43.05, RLM_HVAC_ContractRenew.renewalPrice(41.8));
    }

    @IsTest
    static void aGroupWithoutContractOrdersHasNothingToRenewOrInvoice() {
        Fixture f = fixture();

        RLM_HVAC_ContractRenew.State s = RLM_HVAC_ContractRenew.state(f.open.Id);

        Assert.isFalse(s.hasContract, 'renewal prices come from the contract order products');
        Assert.areEqual(f.parent.Id, s.groupId);
        try {
            RLM_HVAC_ContractRenew.renew(f.parent.Id);
            Assert.fail('nothing to renew');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('no active contract'), e.getMessage());
        }
        Assert.areEqual(0, RLM_HVAC_ContractInvoice.invoiceGroup(f.parent.Id, null));
        RLM_HVAC_ContractInvoice.stampPurchaseOrders(new Set<Id>());
        RLM_HVAC_ContractInvoice.invoicesInserted(new List<Invoice>());
    }

    @IsTest
    static void aLaterContractEndExtendsTheSitesCoverage() {
        Fixture f = fixture();
        RLM_HVAC_CommercialCoverage.activate(new Set<Id>{ f.covered.Id });
        Date renewedEnd = Date.today().addMonths(22);

        Test.startTest();
        update new Asset(Id = f.contractAsset.Id,
            LifecycleEndDate = Datetime.newInstanceGmt(renewedEnd, Time.newInstance(0, 0, 0, 0)));
        Test.stopTest();

        Assert.areEqual(renewedEnd, [SELECT EndDate FROM Entitlement].EndDate);
        Assert.areEqual(renewedEnd, [SELECT EndDate FROM MaintenancePlan].EndDate);
    }
}

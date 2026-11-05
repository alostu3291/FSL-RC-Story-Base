@IsTest
private class RLM_HVAC_RefrigerantComplianceTest {
    private class Fixture {
        Account site;
        Asset tracked;
        Asset small;
        WorkOrder visit;
    }

    private static Fixture fixture() {
        Fixture f = new Fixture();
        insert new WorkType(Name = RLM_HVAC_RefrigerantCompliance.REPAIR_WORK_TYPE, EstimatedDuration = 4,
            DurationType = 'Hours', ShouldAutoCreateSvcAppt = false);
        Account parent = new Account(Name = 'Compliance Test Group', RLM_HVAC_Site_Type__c = 'Headquarters');
        insert parent;
        insert new Contact(AccountId = parent.Id, LastName = 'Director', Title = 'Director of Facilities');
        f.site = new Account(Name = 'Compliance Test Data Room', ParentId = parent.Id, RLM_HVAC_Site_Type__c = 'Data Room',
            RLM_HVAC_Site_Code__c = 'CMP-1');
        insert f.site;
        f.tracked = new Asset(Name = 'RTU-01 IntelliPak 30-ton', AccountId = f.site.Id, RLM_HVAC_Unit_Tag__c = 'RTU-01',
            RLM_HVAC_Tonnage__c = 30, RLM_HVAC_Refrigerant_Type__c = 'R-410A', RLM_HVAC_Refrigerant_Charge__c = 65);
        f.small = new Asset(Name = 'RTU-02 Strategos 10-ton', AccountId = f.site.Id, RLM_HVAC_Unit_Tag__c = 'RTU-02',
            RLM_HVAC_Tonnage__c = 10, RLM_HVAC_Refrigerant_Type__c = 'R-410A', RLM_HVAC_Refrigerant_Charge__c = 23);
        insert new List<Asset>{ f.tracked, f.small };
        f.visit = new WorkOrder(AccountId = f.site.Id, Subject = 'Quarterly visit');
        insert f.visit;
        return f;
    }

    @IsTest
    static void theLeakRateAnnualizesOverTheDaysSinceTheLastAddition() {
        Assert.areEqual(28.1, RLM_HVAC_RefrigerantCompliance.leakRate(6, 65, 120));
        Assert.areEqual(10.0, RLM_HVAC_RefrigerantCompliance.leakRate(6.5, 65, null), 'no previous addition counts a full year');
        Assert.areEqual(10.0, RLM_HVAC_RefrigerantCompliance.leakRate(6.5, 65, 500), 'the period is capped at 365 days');
        Assert.isNull(RLM_HVAC_RefrigerantCompliance.leakRate(5, null, 30));
    }

    @IsTest
    static void aTrackedUnitOverTheLimitGetsARepairAndAFlag() {
        Fixture f = fixture();
        insert new RLM_HVAC_Refrigerant_Log__c(RLM_HVAC_Asset__c = f.tracked.Id, RLM_HVAC_Pounds_Added__c = 2,
            RLM_HVAC_Logged_On__c = Date.today().addDays(-120));

        RLM_HVAC_RefrigerantCompliance.Result r = RLM_HVAC_RefrigerantCompliance.logRefrigerant(f.visit.Id, f.tracked.Id, 6, 'Oil at the coil header');

        Assert.areEqual(28.1, r.leakRate);
        Assert.areEqual(120, r.days);
        Assert.isTrue(r.tracked);
        Assert.isTrue(r.overLimit);
        Assert.areEqual(Date.today().addDays(30), r.repairDue);
        Assert.isNotNull(r.repairWorkOrderNumber);
        Asset a = [SELECT RLM_HVAC_Compliance_Status__c, RLM_HVAC_Leak_Rate__c, RLM_HVAC_Last_Refrigerant_Add__c FROM Asset WHERE Id = :f.tracked.Id];
        Assert.areEqual(RLM_HVAC_RefrigerantCompliance.REPAIR_DUE, a.RLM_HVAC_Compliance_Status__c);
        Assert.areEqual(28.1, a.RLM_HVAC_Leak_Rate__c);
        Assert.areEqual(Date.today(), a.RLM_HVAC_Last_Refrigerant_Add__c);
        WorkOrder repair = [
            SELECT Priority, AssetId, ContactId, (SELECT AssetId FROM WorkOrderLineItems)
            FROM WorkOrder WHERE WorkType.Name = :RLM_HVAC_RefrigerantCompliance.REPAIR_WORK_TYPE
        ];
        Assert.areEqual('High', repair.Priority);
        Assert.areEqual(f.tracked.Id, repair.AssetId);
        Assert.isNotNull(repair.ContactId, 'the facility director is the contact');
        Assert.areEqual(1, repair.WorkOrderLineItems.size());
        RLM_HVAC_Refrigerant_Log__c log = [SELECT RLM_HVAC_Work_Order__c, RLM_HVAC_Technician__c FROM RLM_HVAC_Refrigerant_Log__c
            WHERE RLM_HVAC_Repair_Work_Order__c = :repair.Id];
        Assert.areEqual(f.visit.Id, log.RLM_HVAC_Work_Order__c);
        Assert.areEqual(UserInfo.getUserId(), log.RLM_HVAC_Technician__c);
    }

    @IsTest
    static void anotherAdditionWhileTheRepairIsOpenReusesIt() {
        Fixture f = fixture();
        RLM_HVAC_RefrigerantCompliance.logFor(f.visit.Id, f.tracked.Id, 20, null);
        RLM_HVAC_RefrigerantCompliance.Result second = RLM_HVAC_RefrigerantCompliance.logFor(f.visit.Id, f.tracked.Id, 3, null);

        Assert.isTrue(second.overLimit);
        Assert.areEqual(1, [SELECT COUNT() FROM WorkOrder WHERE WorkType.Name = :RLM_HVAC_RefrigerantCompliance.REPAIR_WORK_TYPE]);
        Assert.areEqual(2, [SELECT COUNT() FROM RLM_HVAC_Refrigerant_Log__c WHERE RLM_HVAC_Repair_Work_Order__c != null]);
    }

    @IsTest
    static void completingTheRepairRestoresCompliance() {
        Fixture f = fixture();
        RLM_HVAC_RefrigerantCompliance.logFor(f.visit.Id, f.tracked.Id, 20, null);
        WorkOrder repair = [SELECT Id FROM WorkOrder WHERE WorkType.Name = :RLM_HVAC_RefrigerantCompliance.REPAIR_WORK_TYPE];

        repair.Status = 'Completed';
        update repair;

        Asset a = [SELECT RLM_HVAC_Compliance_Status__c, RLM_HVAC_Repair_Due_Date__c FROM Asset WHERE Id = :f.tracked.Id];
        Assert.areEqual(RLM_HVAC_RefrigerantCompliance.IN_COMPLIANCE, a.RLM_HVAC_Compliance_Status__c);
        Assert.isNull(a.RLM_HVAC_Repair_Due_Date__c);
    }

    @IsTest
    static void smallUnitsAndAdditionsWithinTheLimitAreNotFlagged() {
        Fixture f = fixture();

        RLM_HVAC_RefrigerantCompliance.Result small = RLM_HVAC_RefrigerantCompliance.logFor(f.visit.Id, f.small.Id, 10, null);
        RLM_HVAC_RefrigerantCompliance.Result within = RLM_HVAC_RefrigerantCompliance.logFor(f.visit.Id, f.tracked.Id, 3, null);

        Assert.isFalse(small.tracked);
        Assert.isFalse(small.overLimit);
        Assert.isFalse(within.overLimit, '3 of 65 lb over a year is 4.6%');
        Assert.areEqual(0, [SELECT COUNT() FROM WorkOrder WHERE WorkType.Name = :RLM_HVAC_RefrigerantCompliance.REPAIR_WORK_TYPE]);
        Asset a = [SELECT RLM_HVAC_Compliance_Status__c FROM Asset WHERE Id = :f.tracked.Id];
        Assert.areEqual(RLM_HVAC_RefrigerantCompliance.IN_COMPLIANCE, a.RLM_HVAC_Compliance_Status__c);
    }

    @IsTest
    static void theStateListsTrackedUnitsFirstAndRejectsBadAmounts() {
        Fixture f = fixture();

        RLM_HVAC_RefrigerantCompliance.State s = RLM_HVAC_RefrigerantCompliance.state(f.visit.Id);
        RLM_HVAC_RefrigerantCompliance.State one = RLM_HVAC_RefrigerantCompliance.state(f.small.Id);

        Assert.areEqual(2, s.units.size());
        Assert.areEqual('RTU-01', s.units[0].tag, 'tracked units come first');
        Assert.isTrue(s.units[0].tracked);
        Assert.areEqual('IntelliPak 30-ton', s.units[0].model);
        Assert.isTrue(one.singleUnit);
        Assert.areEqual(1, one.units.size());
        try {
            RLM_HVAC_RefrigerantCompliance.logRefrigerant(f.visit.Id, f.tracked.Id, 0, null);
            Assert.fail('nothing added is not a log');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Enter the pounds'), e.getMessage());
        }
    }
}

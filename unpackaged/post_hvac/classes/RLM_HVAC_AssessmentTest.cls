@IsTest
private class RLM_HVAC_AssessmentTest {
    private static RLM_HVAC_Finding__c finding(String equipment, String component, String condition, String urgency) {
        return new RLM_HVAC_Finding__c(Equipment__c = equipment, Component__c = component, Condition__c = condition, Urgency__c = urgency);
    }

    private static RLM_HVAC_Finding__c plate(String equipment, Integer yearsOld) {
        return new RLM_HVAC_Finding__c(Equipment__c = equipment, Make__c = 'Carrier', Install_Year__c = Date.today().year() - yearsOld);
    }

    private static RLM_HVAC_Assessment.Recommendation recommend(List<RLM_HVAC_Finding__c> findings) {
        return RLM_HVAC_Assessment.recommend(findings, null);
    }

    private static Id newAssessment() {
        Account acct = new Account(Name = 'System Check Test');
        insert acct;
        RLM_HVAC_Assessment__c assessment = new RLM_HVAC_Assessment__c(Account__c = acct.Id);
        insert assessment;
        return assessment.Id;
    }

    private static RLM_HVAC_Assessment.FindingInput input(String equipment, String component, String condition, String urgency) {
        RLM_HVAC_Assessment.FindingInput f = new RLM_HVAC_Assessment.FindingInput();
        f.equipment = equipment;
        f.component = component;
        f.condition = condition;
        f.urgency = urgency;
        f.customerNote = 'Noticed on the walk';
        return f;
    }

    @IsTest
    static void noFindingsRecommendsBasic() {
        RLM_HVAC_Assessment.Recommendation rec = recommend(new List<RLM_HVAC_Finding__c>());
        Assert.areEqual(RLM_HVAC_Assessment.BASIC, rec.planSku);
        Assert.areEqual('Monitor', rec.urgency);
        Assert.areEqual('0to5', rec.equipmentAge);
        Assert.isFalse(rec.includeIaq);
        Assert.isFalse(rec.includeWaterHeater);
        Assert.isFalse(rec.replacementRecommended);
        Assert.areEqual(1, rec.reasons.size());
    }

    @IsTest
    static void aRepairRecommendsPlusAndPricesTheRepair() {
        RLM_HVAC_Finding__c cap = finding('Outdoor Unit', 'Capacitor', 'Worn', 'Repair Soon');
        cap.Reading__c = '32 µF of 45';
        RLM_HVAC_Assessment.Recommendation rec = recommend(new List<RLM_HVAC_Finding__c>{ cap });
        Assert.areEqual(RLM_HVAC_Assessment.PLUS, rec.planSku);
        Assert.areEqual('Repair Soon', rec.urgency);
        Assert.areEqual(new List<String>{ RLM_HVAC_Assessment.CAPACITOR }, rec.repairSkus);
        Assert.isTrue(rec.summary.contains('Capacitor Replacement: Outdoor Unit: capacitor worn, 32 µF of 45 (repair soon)'), rec.summary);
    }

    @IsTest
    static void monitoredFindingsAreNotedNotRepaired() {
        RLM_HVAC_Assessment.Recommendation rec = recommend(
            new List<RLM_HVAC_Finding__c>{ finding('Outdoor Unit', 'Coil', 'Dirty', 'Monitor') }
        );
        Assert.areEqual(RLM_HVAC_Assessment.BASIC, rec.planSku);
        Assert.isTrue(rec.repairSkus.isEmpty());
    }

    @IsTest
    static void leakingCoilNeedsRefrigerantWork() {
        RLM_HVAC_Assessment.Recommendation rec = recommend(new List<RLM_HVAC_Finding__c>{
            finding('Air Handler', 'Coil', 'Leaking', 'Repair Soon'),
            finding('Air Handler', 'Condensate Drain', 'Clogged', 'Repair Soon')
        });
        Assert.areEqual(RLM_HVAC_Assessment.PREMIER, rec.planSku, 'Two repairs go to Premier');
        Assert.isTrue(rec.repairSkus.contains(RLM_HVAC_Assessment.REFRIGERANT));
        Assert.isTrue(rec.repairSkus.contains(RLM_HVAC_Assessment.DRAIN_CLEAR));
    }

    @IsTest
    static void oldEquipmentIsPricedAndRecommendedForReplacement() {
        RLM_HVAC_Assessment.Recommendation rec = recommend(new List<RLM_HVAC_Finding__c>{ plate('Furnace', 14) });
        Assert.areEqual(14, rec.oldestAge);
        Assert.areEqual('11to15', rec.equipmentAge);
        Assert.isTrue(rec.replacementRecommended);
        Assert.areEqual(RLM_HVAC_Assessment.PREMIER, rec.planSku);
        Assert.isTrue(rec.summary.startsWith('Comfort Premier: Oldest system is 14 years old'), rec.summary);
    }

    @IsTest
    static void agingButNotDueEquipmentRecommendsPlus() {
        RLM_HVAC_Assessment.Recommendation rec = recommend(new List<RLM_HVAC_Finding__c>{
            plate('Outdoor Unit', 11), plate('Thermostat', 30)
        });
        Assert.areEqual(11, rec.oldestAge, 'Only main equipment sets the age');
        Assert.isFalse(rec.replacementRecommended);
        Assert.areEqual(RLM_HVAC_Assessment.PLUS, rec.planSku);
    }

    @IsTest
    static void crackedHeatExchangerIsASafetyReplacement() {
        RLM_HVAC_Assessment.Recommendation rec = recommend(
            new List<RLM_HVAC_Finding__c>{ finding('Furnace', 'Heat Exchanger', 'Cracked', 'Monitor') }
        );
        Assert.isTrue(rec.safetyFlag);
        Assert.areEqual('Safety', rec.urgency);
        Assert.isTrue(rec.replacementRecommended);
        Assert.areEqual(RLM_HVAC_Assessment.PREMIER, rec.planSku);
    }

    @IsTest
    static void indoorAirAndWaterHeaterAddOns() {
        RLM_HVAC_Assessment.Recommendation rec = recommend(new List<RLM_HVAC_Finding__c>{
            finding('Indoor Air', null, 'Allergies Noted', 'Monitor'),
            finding('Water Heater', 'Tank', 'Sediment', 'Monitor')
        });
        Assert.areEqual(RLM_HVAC_Assessment.BASIC, rec.planSku);
        Assert.isTrue(rec.includeIaq);
        Assert.isTrue(rec.includeWaterHeater);
        Assert.areEqual(3, rec.reasons.size());
        Assert.isTrue(rec.summary.contains('Water Heater Care'));
    }

    @IsTest
    static void moreThanOneSystemRecommendsPlus() {
        RLM_HVAC_Assessment.Recommendation rec = RLM_HVAC_Assessment.recommend(
            new List<RLM_HVAC_Finding__c>(),
            new RLM_HVAC_Assessment__c(System_Type__c = 'HeatPump', System_Count__c = 2)
        );
        Assert.areEqual(RLM_HVAC_Assessment.PLUS, rec.planSku);
        Assert.areEqual(2, rec.systemCount);
        Assert.areEqual('HeatPump', rec.systemType);
    }

    @IsTest
    static void saveEditDeleteAndQuote() {
        Id assessmentId = newAssessment();
        Test.startTest();
        RLM_HVAC_Assessment.AssessmentState state = RLM_HVAC_Assessment.saveSystems(assessmentId, 'AcFurnace', 1);
        state = RLM_HVAC_Assessment.saveFinding(assessmentId, input('Outdoor Unit', 'Contactor', 'Worn', 'Repair Soon'));
        Assert.areEqual(1, state.findings.size());
        Assert.areEqual(RLM_HVAC_Assessment.PLUS, state.recommendation.planSku);

        Id findingId = state.findings[0].id;
        insert new ContentVersion(
            Title = 'photo',
            PathOnClient = 'photo.jpg',
            VersionData = Blob.valueOf('img'),
            FirstPublishLocationId = findingId
        );
        state = RLM_HVAC_Assessment.getState(assessmentId);
        Assert.areEqual(1, state.findings[0].photos.size());

        RLM_HVAC_Assessment.FindingInput edit = input('Outdoor Unit', 'Contactor', 'Failed', 'Safety');
        edit.id = findingId;
        state = RLM_HVAC_Assessment.saveFinding(assessmentId, edit);
        Assert.areEqual(RLM_HVAC_Assessment.PREMIER, state.recommendation.planSku);

        RLM_HVAC_Assessment__c saved = [
            SELECT Recommended_Plan__c, Overall_Urgency__c FROM RLM_HVAC_Assessment__c WHERE Id = :assessmentId
        ];
        Assert.areEqual(RLM_HVAC_Assessment.PREMIER, saved.Recommended_Plan__c);
        Assert.areEqual('Safety', saved.Overall_Urgency__c);

        state = RLM_HVAC_Assessment.deleteFinding(assessmentId, findingId);
        Assert.areEqual(0, state.findings.size());
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocument WHERE Title = 'photo']);

        RLM_HVAC_Assessment.markQuoted(assessmentId, null, 'Customer asked for the smaller agreement');
        Test.stopTest();

        saved = [SELECT Status__c, Override_Reason__c FROM RLM_HVAC_Assessment__c WHERE Id = :assessmentId];
        Assert.areEqual('Quoted', saved.Status__c);
        Assert.areEqual('Customer asked for the smaller agreement', saved.Override_Reason__c);
    }

    @IsTest
    static void quoteFindingsHideInternalNotes() {
        Id assessmentId = newAssessment();
        RLM_HVAC_Assessment.FindingInput f = input('Indoor Air', 'Filter', 'Clogged', 'Monitor');
        f.internalNote = 'Offer a media filter next visit';
        RLM_HVAC_Assessment.saveFinding(assessmentId, f);

        Assert.isNull(RLM_HVAC_Assessment.getQuoteFindings(null));
        Id accountId = [SELECT Account__c FROM RLM_HVAC_Assessment__c WHERE Id = :assessmentId].Account__c;
        Opportunity opp = new Opportunity(
            Name = 'System Check Quote', AccountId = accountId, StageName = 'Prospecting', CloseDate = Date.today()
        );
        insert opp;
        Quote q = new Quote(Name = 'System Check Quote', OpportunityId = opp.Id);
        insert q;
        RLM_HVAC_Assessment.markQuoted(assessmentId, q.Id, null);

        RLM_HVAC_Assessment.AssessmentState state = RLM_HVAC_Assessment.getQuoteFindings(q.Id);
        Assert.areEqual(1, state.findings.size());
        Assert.isNull(state.findings[0].internalNote);
        Assert.isNull(state.findings[0].recommendedProductName, 'Indoor Air Quality is not on the quote');
        Assert.isNotNull(state.assessmentName);
        Assert.areEqual(
            'Filter – Clogged',
            [SELECT Observation__c FROM RLM_HVAC_Finding__c WHERE Assessment__c = :assessmentId].Observation__c
        );
    }

    @IsTest
    static void thePriceNoteExplainsTheAgeAdjustment() {
        RLM_HVAC_Assessment__c priced = new RLM_HVAC_Assessment__c(Equipment_Age__c = '11to15', Age_Adjustment__c = 6);
        Assert.areEqual(
            'Your Comfort Plus price of $35/mo per system includes a $6/mo equipment age adjustment '
                + '(equipment 11–15 years old +$6). It comes off when the equipment is replaced.',
            RLM_HVAC_Assessment.priceNote('Comfort Plus', 35, priced)
        );
        priced.Age_Adjustment__c = 0;
        Assert.isNull(RLM_HVAC_Assessment.priceNote('Comfort Plus', 29, priced), 'No note without an adjustment');
    }

    @IsTest
    static void workOrderServiceAndAfterPhotos() {
        Id assessmentId = newAssessment();
        RLM_HVAC_Assessment.AssessmentState walk = RLM_HVAC_Assessment.saveFinding(
            assessmentId,
            input('Outdoor Unit', 'Coil', 'Dirty', 'Repair Soon')
        );
        Id findingId = walk.findings[0].id;
        insert new ContentVersion(
            Title = 'before', PathOnClient = 'before.jpg', VersionData = Blob.valueOf('b'),
            FirstPublishLocationId = findingId
        );
        Id accountId = [SELECT Account__c FROM RLM_HVAC_Assessment__c WHERE Id = :assessmentId].Account__c;
        WorkOrder wo = new WorkOrder(Subject = 'Initial Tune-up', AccountId = accountId, RLM_HVAC_Assessment__c = assessmentId);
        insert wo;

        Assert.isNull(RLM_HVAC_Assessment.getWorkOrderFindings(null));
        Test.startTest();
        RLM_HVAC_Assessment.AssessmentState state = RLM_HVAC_Assessment.getWorkOrderFindings(wo.Id);
        Assert.areEqual(1, state.findings.size());
        Assert.areEqual('Open', state.findings[0].workStatus);
        Assert.areEqual(0, state.doneCount);

        state = RLM_HVAC_Assessment.saveWork(wo.Id, findingId, 'Done', 'Cleaned the condenser coil', 'Temp split 19 °F');
        Assert.areEqual(1, state.doneCount);
        Assert.areEqual('Cleaned the condenser coil', state.findings[0].workNote);
        Assert.areEqual('Temp split 19 °F', state.findings[0].reading);
        Assert.isNotNull(state.findings[0].completedOn);

        ContentVersion after = new ContentVersion(
            Title = 'after', PathOnClient = 'after.jpg', VersionData = Blob.valueOf('a'),
            FirstPublishLocationId = findingId
        );
        insert after;
        Id afterDoc = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :after.Id].ContentDocumentId;
        state = RLM_HVAC_Assessment.tagAfterPhotos(wo.Id, findingId, new List<Id>{ afterDoc });
        Test.stopTest();

        Assert.areEqual(1, state.findings[0].photos.size());
        Assert.areEqual(1, state.findings[0].afterPhotos.size());
        Assert.areEqual('After', state.findings[0].afterPhotos[0].stage);
    }

    @IsTest
    static void tuneUpStepsFollowTheSystemAndTheSeason() {
        List<RLM_HVAC_Assessment.ServiceStep> spring = RLM_HVAC_Assessment.stepsFor('AcFurnace', 'Spring AC Tune-up', null);
        List<RLM_HVAC_Assessment.ServiceStep> fall = RLM_HVAC_Assessment.stepsFor('AcFurnace', 'Fall Furnace Tune-up', null);
        Set<String> springKeys = new Set<String>();
        for (RLM_HVAC_Assessment.ServiceStep s : spring) {
            springKeys.add(s.key);
        }
        Set<String> fallKeys = new Set<String>();
        for (RLM_HVAC_Assessment.ServiceStep s : fall) {
            fallKeys.add(s.key);
        }
        Assert.isTrue(springKeys.contains('capacitor'));
        Assert.isFalse(springKeys.contains('co'), 'No CO test on an AC tune-up');
        Assert.isTrue(fallKeys.contains('co'));
        Assert.isFalse(fallKeys.contains('condenser'));
        Assert.isTrue(springKeys.contains('filter') && fallKeys.contains('filter'));
        Assert.isTrue(RLM_HVAC_Assessment.stepsFor('Boiler', null, null)[0].key == 'pressure');
        Assert.isFalse(RLM_HVAC_Assessment.stepsFor('Unknown', null, 'not json').isEmpty(), 'Unknown system types get the AC and furnace steps');
    }

    @IsTest
    static void tuneUpStepsAndReadingsAreKeptOnTheWorkOrder() {
        WorkType spring = new WorkType(Name = 'Spring AC Tune-up', EstimatedDuration = 1.5, DurationType = 'Hours');
        insert spring;
        Account acct = new Account(Name = 'Tune-up Home');
        insert acct;
        WorkOrder wo = new WorkOrder(AccountId = acct.Id, WorkTypeId = spring.Id, Subject = 'Spring AC Tune-up');
        insert wo;

        RLM_HVAC_Assessment.AssessmentState state = RLM_HVAC_Assessment.getWorkOrderFindings(wo.Id);
        Assert.areEqual('AcFurnace', state.systemType, 'No system check: assume AC and furnace');
        Assert.areEqual('Spring AC Tune-up', state.workTypeName);
        Assert.areEqual(0, state.stepsDone);
        Assert.isTrue(state.findings.isEmpty());

        state = RLM_HVAC_Assessment.saveStep(wo.Id, 'capacitor', true, ' 43 µF of 45 ');
        Assert.areEqual(1, state.stepsDone);
        for (RLM_HVAC_Assessment.ServiceStep s : state.steps) {
            if (s.key == 'capacitor') {
                Assert.isTrue(s.done);
                Assert.areEqual('43 µF of 45', s.reading);
                Assert.areEqual('µF', s.readingHint);
            }
        }
        state = RLM_HVAC_Assessment.saveStep(wo.Id, 'capacitor', false, null);
        Assert.areEqual(0, state.stepsDone);
    }

    @IsTest
    static void serviceRejectsFindingFromAnotherSystemCheck() {
        Id assessmentId = newAssessment();
        Id otherFinding = RLM_HVAC_Assessment.saveFinding(newAssessment(), input('Thermostat', 'Thermostat', 'Worn', 'Monitor'))
            .findings[0].id;
        WorkOrder wo = new WorkOrder(Subject = 'Initial Tune-up', RLM_HVAC_Assessment__c = assessmentId);
        insert wo;
        try {
            RLM_HVAC_Assessment.saveWork(wo.Id, otherFinding, 'Done', null, null);
            Assert.fail('Expected the finding to be rejected');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not part of this work order'), e.getMessage());
        }
    }

    @IsTest
    static void saveErrorsSurfaceAsAuraException() {
        try {
            RLM_HVAC_Assessment.saveFinding(newAssessment(), input('Outdoor Unit', 'Not A Component', null, 'Monitor'));
            Assert.fail('Expected an exception for a restricted picklist value');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage());
        }
    }
}

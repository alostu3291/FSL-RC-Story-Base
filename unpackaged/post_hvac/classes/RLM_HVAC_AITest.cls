@IsTest
private class RLM_HVAC_AITest {
    private class StubGenerator implements RLM_HVAC_AI.Generator {
        Map<String, String> replies = new Map<String, String>();
        Integer calls = 0;
        Map<String, Object> lastInputs;

        public String generate(String templateName, Map<String, Object> inputs) {
            calls++;
            lastInputs = inputs;
            if (!replies.containsKey(templateName)) {
                throw new CalloutException('Einstein is off');
            }
            return replies.get(templateName);
        }
    }

    private static StubGenerator stub() {
        StubGenerator generator = new StubGenerator();
        RLM_HVAC_AI.generator = generator;
        return generator;
    }

    private static Account customer() {
        Account account = new Account(Name = 'AI Test Home', ShippingPostalCode = '60540');
        insert account;
        insert new Contact(AccountId = account.Id, FirstName = 'Dana', LastName = 'Whitfield', Email = 'dana@example.com');
        return account;
    }

    private static Id assessmentFor(Id accountId) {
        RLM_HVAC_Assessment__c assessment = new RLM_HVAC_Assessment__c(Account__c = accountId, Status__c = 'In Progress');
        insert assessment;
        return assessment.Id;
    }

    private static RLM_HVAC_Finding__c finding(Id assessmentId, String equipment, String component, String condition, String note) {
        RLM_HVAC_Finding__c f = new RLM_HVAC_Finding__c(
            Assessment__c = assessmentId,
            Equipment__c = equipment,
            Component__c = component,
            Condition__c = condition,
            Urgency__c = 'Repair Soon',
            Customer_Note__c = note
        );
        insert f;
        return f;
    }

    @IsTest
    static void briefFallsBackToTheRecordsWithoutEinstein() {
        stub();
        Account account = customer();
        Id assessmentId = assessmentFor(account.Id);
        finding(assessmentId, 'Outdoor Unit', 'Capacitor', 'Worn', 'Unit hums before it starts');
        WorkOrder wo = new WorkOrder(AccountId = account.Id, Subject = 'Customer says the AC is slow to start',
            RLM_HVAC_Assessment__c = assessmentId);
        insert wo;

        RLM_HVAC_AI.Brief brief = RLM_HVAC_AI.getBrief(wo.Id, false);

        Assert.isFalse(brief.aiGenerated);
        Assert.areEqual('System check for AI Test Home', brief.headline);
        Assert.isTrue(String.join(brief.points, ' ').contains('No comfort agreement yet.'));
        Assert.areEqual('Outdoor Unit: capacitor worn (repair soon)', brief.lookFor[0]);
        Assert.isNotNull([SELECT RLM_HVAC_AI_Brief__c FROM WorkOrder WHERE Id = :wo.Id].RLM_HVAC_AI_Brief__c);
    }

    @IsTest
    static void einsteinBriefIsKeptOnTheWorkOrder() {
        StubGenerator generator = stub();
        generator.replies.put(RLM_HVAC_AI.BRIEF_TEMPLATE,
            '```json\n{"headline":"No-cool follow-up on a 2009 condenser","points":["Capacitor was weak last visit"],"lookFor":["Capacitor reading"]}\n```');
        Account account = customer();
        WorkOrder wo = new WorkOrder(AccountId = account.Id, Subject = 'Follow-up');
        insert wo;

        RLM_HVAC_AI.Brief first = RLM_HVAC_AI.getBrief(wo.Id, false);
        RLM_HVAC_AI.Brief second = RLM_HVAC_AI.getBrief(wo.Id, false);

        Assert.isTrue(first.aiGenerated);
        Assert.areEqual('No-cool follow-up on a 2009 condenser', second.headline);
        Assert.areEqual('Capacitor reading', second.lookFor[0]);
        Assert.areEqual(1, generator.calls, 'The saved brief is reused');
        Assert.isTrue(((String) generator.lastInputs.get('Context')).contains('Customer: AI Test Home'));
    }

    @IsTest
    static void photoSuggestionReadsTheDataPlateAndKeepsOnlyAllowedValues() {
        StubGenerator generator = stub();
        generator.replies.put(RLM_HVAC_AI.PHOTO_TEMPLATE,
            '{"component":"capacitor","condition":"Bulging","urgency":"repair soon","make":"Carrier",'
            + '"modelNumber":"24ACC636A003","serialNumber":"1809E12345","installYear":"2009",'
            + '"observation":"Data plate and a bulging run capacitor","customerNote":"Your capacitor is wearing out."}');
        Id assessmentId = assessmentFor(customer().Id);
        RLM_HVAC_Finding__c f = finding(assessmentId, 'Outdoor Unit', null, null, null);
        ContentVersion photo = new ContentVersion(Title = 'plate', PathOnClient = 'plate.jpg',
            VersionData = Blob.valueOf('jpeg'), FirstPublishLocationId = f.Id);
        insert photo;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :photo.Id].ContentDocumentId;

        RLM_HVAC_AI.FindingSuggestion s = RLM_HVAC_AI.suggestFromPhoto(f.Id, documentId);

        Assert.isTrue(s.aiGenerated);
        Assert.areEqual('Capacitor', s.component);
        Assert.isNull(s.condition, 'Values outside the picklist are dropped');
        Assert.areEqual('Repair Soon', s.urgency);
        Assert.areEqual('Outdoor Unit', s.equipment);
        Assert.areEqual('Carrier', s.make);
        Assert.areEqual('24ACC636A003', s.modelNumber);
        Assert.areEqual(2009, s.installYear);
        Assert.areEqual('Data plate and a bulging run capacitor', s.observation);
        Assert.areEqual(new Map<String, String>{ 'id' => documentId }, generator.lastInputs.get('Photo'));
    }

    @IsTest
    static void photoMustBeOnTheFinding() {
        stub();
        RLM_HVAC_Finding__c f = finding(assessmentFor(customer().Id), 'Thermostat', 'Thermostat', null, null);
        ContentVersion elsewhere = new ContentVersion(Title = 'x', PathOnClient = 'x.jpg', VersionData = Blob.valueOf('x'));
        insert elsewhere;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :elsewhere.Id].ContentDocumentId;
        try {
            RLM_HVAC_AI.suggestFromPhoto(f.Id, documentId);
            Assert.fail('Expected an error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not on this finding'));
        }
    }

    @IsTest
    static void dictatedNotesFallBackToKeywords() {
        stub();
        RLM_HVAC_AI.FindingSuggestion s = RLM_HVAC_AI.parseNotes(
            'Capacitor reading 32 uF of 45, pretty worn, unit installed 2009, needs replacing soon', 'Outdoor Unit');

        Assert.isFalse(s.aiGenerated);
        Assert.areEqual('Outdoor Unit', s.equipment);
        Assert.areEqual('Capacitor', s.component);
        Assert.areEqual('Worn', s.condition);
        Assert.areEqual('Repair Soon', s.urgency);
        Assert.areEqual(2009, s.installYear);
        Assert.areEqual('Capacitor reading 32 uF of 45', s.reading);
    }

    @IsTest
    static void keywordsSpotSafetyFindings() {
        stub();
        RLM_HVAC_AI.FindingSuggestion s = RLM_HVAC_AI.parseNotes('Cracked heat exchanger, CO reading high at the register', null);
        Assert.areEqual('Furnace', s.equipment);
        Assert.areEqual('Heat Exchanger', s.component);
        Assert.areEqual('Cracked', s.condition);
        Assert.areEqual('Safety', s.urgency);
        Assert.isNull(RLM_HVAC_AI.yearIn('model 2100 unit'), 'Not a plausible install year');
    }

    @IsTest
    static void dictatedNotesUseEinstein() {
        StubGenerator generator = stub();
        generator.replies.put(RLM_HVAC_AI.NOTES_TEMPLATE,
            '{"equipment":"Furnace","component":"Igniter","condition":"Worn","urgency":"Repair Soon","reading":"igniter 38 ohms",'
            + '"customerNote":"The igniter is near the end of its life.","internalNote":"Bring a hot surface igniter"}');

        RLM_HVAC_AI.FindingSuggestion s = RLM_HVAC_AI.parseNotes('igniter is glowing weak, reads 38 ohms', 'Outdoor Unit');

        Assert.isTrue(s.aiGenerated);
        Assert.areEqual('Furnace', s.equipment);
        Assert.areEqual('Igniter', s.component);
        Assert.areEqual('igniter 38 ohms', s.reading);
        Assert.areEqual('Bring a hot surface igniter', s.internalNote);
        Assert.areEqual('igniter is glowing weak, reads 38 ohms', generator.lastInputs.get('Notes'));
    }

    @IsTest
    static void explanationIsKeptUntilTheRecommendationChanges() {
        StubGenerator generator = stub();
        generator.replies.put(RLM_HVAC_AI.EXPLAIN_TEMPLATE, 'We recommend Comfort Plus because of the worn capacitor.');
        Id assessmentId = assessmentFor(customer().Id);
        finding(assessmentId, 'Outdoor Unit', 'Capacitor', 'Worn', null);
        RLM_HVAC_Assessment.getState(assessmentId);

        String first = RLM_HVAC_AI.explainPlan(assessmentId);
        String again = RLM_HVAC_AI.explainPlan(assessmentId);

        Assert.areEqual('We recommend Comfort Plus because of the worn capacitor.', first);
        Assert.areEqual(first, again);
        Assert.areEqual(1, generator.calls, 'Kept while the recommendation is the same');

        finding(assessmentId, 'Outdoor Unit', 'Contactor', 'Worn', null);
        RLM_HVAC_Assessment.getState(assessmentId);
        RLM_HVAC_AI.explainPlan(assessmentId);
        Assert.areEqual(2, generator.calls, 'Rewritten when the recommendation changes');
    }

    @IsTest
    static void explanationFallsBackToTheRulesAndReachesTheQuote() {
        stub();
        Account account = customer();
        Id assessmentId = assessmentFor(account.Id);
        finding(assessmentId, 'Outdoor Unit', 'Capacitor', 'Worn', null);
        RLM_HVAC_Assessment.getState(assessmentId);

        String text = RLM_HVAC_AI.explainPlan(assessmentId);

        Assert.isTrue(text.startsWith('Based on what we found today, we recommend Comfort Plus: Repairs found today'), text);
        Assert.isTrue(text.contains('We also recommend Capacitor Replacement for Outdoor Unit: capacitor worn (repair soon).'), text);
        Opportunity opportunity = new Opportunity(Name = 'AI Opp', StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30), AccountId = account.Id);
        insert opportunity;
        Quote q = new Quote(Name = 'AI Quote', OpportunityId = opportunity.Id, Pricebook2Id = Test.getStandardPricebookId());
        insert q;
        RLM_HVAC_Assessment.markQuoted(assessmentId, q.Id, null);
        Assert.areEqual(text, [SELECT RLM_HVAC_Plan_Explanation__c FROM Quote WHERE Id = :q.Id].RLM_HVAC_Plan_Explanation__c);
        Assert.areEqual(text, RLM_HVAC_Assessment.getQuoteFindings(q.Id).planExplanation);
    }

    @IsTest
    static void productSuggestionsKeepOnlyOfferedSkus() {
        StubGenerator generator = stub();
        generator.replies.put(RLM_HVAC_AI.SUGGEST_TEMPLATE,
            '{"suggestions":[{"sku":"HVAC-WATER-HEATER","reason":"Water heater is 12 years old and rumbling"},'
            + '{"sku":"HVAC-MADE-UP","reason":"Not offered"},{"sku":"HVAC-WATER-HEATER","reason":"Duplicate"}]}');
        Account account = customer();
        finding(assessmentFor(account.Id), 'Water Heater', null, null, 'Rumbling when it heats');

        List<RLM_HVAC_AI.Pick> picks = RLM_HVAC_AI.suggestProducts(account.Id, new List<RLM_HVAC_AI.Option>{
            new RLM_HVAC_AI.Option('HVAC-WATER-HEATER', 'Water Heater Care', 'Yearly flush and anode check'),
            new RLM_HVAC_AI.Option('HVAC-IAQ', 'Indoor Air Quality', null)
        }, 'comfort agreements');

        Assert.areEqual(1, picks.size());
        Assert.areEqual('HVAC-WATER-HEATER', picks[0].sku);
        Assert.areEqual('Water heater is 12 years old and rumbling', picks[0].reason);
        Assert.isTrue(((String) generator.lastInputs.get('Context')).contains('HVAC-IAQ | Indoor Air Quality'));
    }

    @IsTest
    static void productSuggestionsAreEmptyWithoutEinstein() {
        stub();
        Account account = customer();
        finding(assessmentFor(account.Id), 'Water Heater', null, null, 'Rumbling');
        Assert.isTrue(RLM_HVAC_AI.suggestProducts(account.Id, new List<RLM_HVAC_AI.Option>{
            new RLM_HVAC_AI.Option('HVAC-WATER-HEATER', 'Water Heater Care', null) }, 'comfort agreements').isEmpty());
    }

    @IsTest
    static void summaryIsSavedAndSentOnce() {
        stub();
        Account account = customer();
        Id assessmentId = assessmentFor(account.Id);
        RLM_HVAC_Finding__c f = finding(assessmentId, 'Outdoor Unit', 'Capacitor', 'Worn', null);
        update new RLM_HVAC_Finding__c(Id = f.Id, Work_Status__c = 'Done');
        WorkOrder wo = new WorkOrder(AccountId = account.Id, Subject = 'Spring AC Tune-up', RLM_HVAC_Assessment__c = assessmentId,
            Status = 'Completed',
            RLM_HVAC_Service_Steps__c = '{"capacitor":{"done":true,"reading":"43 µF"},"filter":{"done":false}}');
        insert wo;

        RLM_HVAC_AI.Summary summary = RLM_HVAC_AI.summarizeVisit(wo.Id);
        Assert.isTrue(summary.text.contains('Your tune-up:\n- Test the run capacitor (43 µF)'), summary.text);
        Assert.isFalse(summary.text.contains('Replace the air filter'), 'Only steps done are listed');

        Assert.isFalse(summary.aiGenerated);
        Assert.isTrue(summary.text.startsWith('Hi Dana,'), summary.text);
        Assert.isTrue(summary.text.contains('What we took care of:'), summary.text);
        Assert.isTrue(summary.text.contains('- Outdoor Unit: capacitor worn (repair soon)'), summary.text);
        Assert.isTrue(summary.emailedTo == 'dana@example.com' || summary.emailError != null);
        WorkOrder saved = [SELECT RLM_HVAC_Visit_Summary__c, RLM_HVAC_Summary_Sent_At__c FROM WorkOrder WHERE Id = :wo.Id];
        Assert.areEqual(summary.text, saved.RLM_HVAC_Visit_Summary__c);
        if (summary.emailedTo != null) {
            Assert.isNotNull(saved.RLM_HVAC_Summary_Sent_At__c);
            Assert.areEqual(summary.text, RLM_HVAC_AI.summarizeVisit(wo.Id).text, 'A sent summary is not rewritten');
        }
    }

    @IsTest
    static void summaryWaitsForTheVisitToBeComplete() {
        stub();
        WorkOrder wo = new WorkOrder(AccountId = customer().Id, Subject = 'Spring AC Tune-up');
        insert wo;
        try {
            RLM_HVAC_AI.summarizeVisit(wo.Id);
            Assert.fail('Expected an error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Complete the visit'));
        }
    }

    @IsTest
    static void ruleExplanationWithoutFindings() {
        Assert.isTrue(RLM_HVAC_AI.ruleExplanation(null).contains('Comfort Basic'));
    }

    @IsTest
    static void suggestionsThatAdmitNoEvidenceAreDropped() {
        Assert.isTrue(RLM_HVAC_AI.isUnsupported('No refrigerant leak found, recharge not needed.'));
        Assert.isTrue(RLM_HVAC_AI.isUnsupported('Potential capacitor wear.'));
        Assert.isFalse(RLM_HVAC_AI.isUnsupported('Capacitor reads 32 µF of 45'));
    }

    @IsTest
    static void suggestionsMustRepairTheComponentTheyName() {
        RLM_HVAC_AI.Option refrigerant = new RLM_HVAC_AI.Option('HVAC-REFRIGERANT', 'Refrigerant Leak Check and Recharge',
            'Find and fix the leak, then recharge the system.');
        Assert.isFalse(RLM_HVAC_AI.covers(refrigerant, 'Blower motor is loud at startup.'));
        Assert.isTrue(RLM_HVAC_AI.covers(refrigerant, 'Suction pressure low, likely low on refrigerant'));
        Assert.isTrue(RLM_HVAC_AI.covers(refrigerant, 'Unit short-cycles on hot days'));
    }
}

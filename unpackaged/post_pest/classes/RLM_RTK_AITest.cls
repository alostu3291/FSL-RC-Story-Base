@IsTest
private class RLM_RTK_AITest {
    private class StubGenerator implements RLM_RTK_AI.Generator {
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
        RLM_RTK_AI.generator = generator;
        return generator;
    }

    private static Account customer() {
        Account account = new Account(Name = 'AI Test Home', ShippingPostalCode = '60108');
        insert account;
        insert new Contact(AccountId = account.Id, FirstName = 'Dana', LastName = 'Whitfield', Email = 'dana@example.com');
        return account;
    }

    private static Id inspectionFor(Id accountId) {
        RLM_RTK_Inspection__c inspection = new RLM_RTK_Inspection__c(Account__c = accountId, Status__c = 'In Progress');
        insert inspection;
        return inspection.Id;
    }

    private static RLM_RTK_Finding__c finding(Id inspectionId, String zone, String pest, String evidence, String note) {
        RLM_RTK_Finding__c f = new RLM_RTK_Finding__c(
            Inspection__c = inspectionId,
            Zone__c = zone,
            Pest__c = pest,
            Evidence__c = evidence,
            Severity__c = 'Moderate',
            Customer_Note__c = note
        );
        insert f;
        return f;
    }

    @IsTest
    static void briefFallsBackToTheRecordsWithoutEinstein() {
        stub();
        Account account = customer();
        Id inspectionId = inspectionFor(account.Id);
        finding(inspectionId, 'Garage', 'Rodents', 'Entry Point', 'Gap under the side door');
        WorkOrder wo = new WorkOrder(AccountId = account.Id, Subject = 'Customer heard scratching in the garage',
            RLM_RTK_Inspection__c = inspectionId);
        insert wo;

        RLM_RTK_AI.Brief brief = RLM_RTK_AI.getBrief(wo.Id, false);

        Assert.isFalse(brief.aiGenerated);
        Assert.areEqual('Inspection visit for AI Test Home', brief.headline);
        Assert.isTrue(String.join(brief.points, ' ').contains('No active service plans yet.'));
        Assert.areEqual('Garage: rodents, entry point (moderate)', brief.lookFor[0]);
        Assert.isNotNull([SELECT RLM_RTK_AI_Brief__c FROM WorkOrder WHERE Id = :wo.Id].RLM_RTK_AI_Brief__c);
    }

    @IsTest
    static void einsteinBriefIsKeptOnTheWorkOrder() {
        StubGenerator generator = stub();
        generator.replies.put(RLM_RTK_AI.BRIEF_TEMPLATE,
            '```json\n{"headline":"Rodent follow-up in the garage","points":["Heard scratching"],"lookFor":["Garage door seal"]}\n```');
        Account account = customer();
        WorkOrder wo = new WorkOrder(AccountId = account.Id, Subject = 'Follow-up');
        insert wo;

        RLM_RTK_AI.Brief first = RLM_RTK_AI.getBrief(wo.Id, false);
        RLM_RTK_AI.Brief second = RLM_RTK_AI.getBrief(wo.Id, false);

        Assert.isTrue(first.aiGenerated);
        Assert.areEqual('Rodent follow-up in the garage', second.headline);
        Assert.areEqual('Garage door seal', second.lookFor[0]);
        Assert.areEqual(1, generator.calls, 'The saved brief is reused');
        Assert.isTrue(((String) generator.lastInputs.get('Context')).contains('Customer: AI Test Home'));
    }

    @IsTest
    static void photoSuggestionKeepsOnlyAllowedValues() {
        StubGenerator generator = stub();
        generator.replies.put(RLM_RTK_AI.PHOTO_TEMPLATE,
            '{"pest":"wasps / bees","evidence":"Hive","severity":"Moderate","observation":"Paper nest under the eave",'
            + '"customerNote":"We found a wasp nest under the eave."}');
        Id inspectionId = inspectionFor(customer().Id);
        RLM_RTK_Finding__c f = finding(inspectionId, 'Exterior Perimeter', null, null, null);
        ContentVersion photo = new ContentVersion(Title = 'eave', PathOnClient = 'eave.jpg',
            VersionData = Blob.valueOf('jpeg'), FirstPublishLocationId = f.Id);
        insert photo;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :photo.Id].ContentDocumentId;

        RLM_RTK_AI.FindingSuggestion s = RLM_RTK_AI.suggestFromPhoto(f.Id, documentId);

        Assert.isTrue(s.aiGenerated);
        Assert.areEqual('Wasps / Bees', s.pest);
        Assert.isNull(s.evidence, 'Values outside the picklist are dropped');
        Assert.areEqual('Moderate', s.severity);
        Assert.areEqual('Exterior Perimeter', s.zone);
        Assert.areEqual('Paper nest under the eave', s.observation);
        Assert.areEqual(new Map<String, String>{ 'id' => documentId }, generator.lastInputs.get('Photo'));
    }

    @IsTest
    static void photoMustBeOnTheFinding() {
        stub();
        RLM_RTK_Finding__c f = finding(inspectionFor(customer().Id), 'Garage', 'Ants', null, null);
        ContentVersion elsewhere = new ContentVersion(Title = 'x', PathOnClient = 'x.jpg', VersionData = Blob.valueOf('x'));
        insert elsewhere;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :elsewhere.Id].ContentDocumentId;
        try {
            RLM_RTK_AI.suggestFromPhoto(f.Id, documentId);
            Assert.fail('Expected an error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not on this finding'));
        }
    }

    @IsTest
    static void dictatedNotesFallBackToKeywords() {
        stub();
        RLM_RTK_AI.FindingSuggestion s = RLM_RTK_AI.parseNotes(
            'Lots of mud tubes on the garage wall by the water heater', 'Garage');

        Assert.isFalse(s.aiGenerated);
        Assert.areEqual('Garage', s.zone);
        Assert.areEqual('Termites', s.pest);
        Assert.areEqual('Damage', s.evidence);
        Assert.areEqual('Heavy', s.severity);
    }

    @IsTest
    static void dictatedNotesUseEinstein() {
        StubGenerator generator = stub();
        generator.replies.put(RLM_RTK_AI.NOTES_TEMPLATE,
            '{"zone":"Attic","pest":"Rodents","evidence":"Droppings","severity":"Heavy",'
            + '"customerNote":"Droppings across the attic insulation.","internalNote":"Bring a ladder"}');

        RLM_RTK_AI.FindingSuggestion s = RLM_RTK_AI.parseNotes('mouse droppings all over the attic', 'Garage');

        Assert.isTrue(s.aiGenerated);
        Assert.areEqual('Attic', s.zone);
        Assert.areEqual('Rodents', s.pest);
        Assert.areEqual('Bring a ladder', s.internalNote);
        Assert.areEqual('mouse droppings all over the attic', generator.lastInputs.get('Notes'));
    }

    @IsTest
    static void explanationIsKeptUntilTheRecommendationChanges() {
        StubGenerator generator = stub();
        generator.replies.put(RLM_RTK_AI.EXPLAIN_TEMPLATE, 'We recommend Home Protection because of the garage gap.');
        Id inspectionId = inspectionFor(customer().Id);
        finding(inspectionId, 'Garage', 'Rodents', 'Entry Point', null);
        RLM_RTK_Inspection.getState(inspectionId);

        String first = RLM_RTK_AI.explainPlan(inspectionId);
        String again = RLM_RTK_AI.explainPlan(inspectionId);

        Assert.areEqual('We recommend Home Protection because of the garage gap.', first);
        Assert.areEqual(first, again);
        Assert.areEqual(1, generator.calls, 'Kept while the recommendation is the same');

        finding(inspectionId, 'Yard', 'Mosquitoes', 'Standing Water', null);
        RLM_RTK_Inspection.getState(inspectionId);
        RLM_RTK_AI.explainPlan(inspectionId);
        Assert.areEqual(2, generator.calls, 'Rewritten when the recommendation changes');
    }

    @IsTest
    static void explanationFallsBackToTheRulesAndReachesTheQuote() {
        stub();
        Account account = customer();
        Id inspectionId = inspectionFor(account.Id);
        finding(inspectionId, 'Garage', 'Rodents', 'Entry Point', null);
        RLM_RTK_Inspection.getState(inspectionId);

        String text = RLM_RTK_AI.explainPlan(inspectionId);

        Assert.isTrue(text.startsWith('Based on what we found today, we recommend the Home Protection Plan'), text);
        Opportunity opportunity = new Opportunity(Name = 'AI Opp', StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30), AccountId = account.Id);
        insert opportunity;
        Quote q = new Quote(Name = 'AI Quote', OpportunityId = opportunity.Id, Pricebook2Id = Test.getStandardPricebookId());
        insert q;
        RLM_RTK_Inspection.markQuoted(inspectionId, q.Id, null);
        Assert.areEqual(text, [SELECT RLM_RTK_Plan_Explanation__c FROM Quote WHERE Id = :q.Id].RLM_RTK_Plan_Explanation__c);
        Assert.areEqual(text, RLM_RTK_Inspection.getQuoteFindings(q.Id).planExplanation);
    }

    @IsTest
    static void productSuggestionsKeepOnlyOfferedSkus() {
        StubGenerator generator = stub();
        generator.replies.put(RLM_RTK_AI.SUGGEST_TEMPLATE,
            '{"suggestions":[{"sku":"RTK-TERMITE","reason":"Mud tubes on the garage wall"},'
            + '{"sku":"RTK-MADE-UP","reason":"Not offered"},{"sku":"RTK-TERMITE","reason":"Duplicate"}]}');
        Account account = customer();
        finding(inspectionFor(account.Id), 'Garage', 'Other', null, 'Mud tubes on the garage wall');

        List<RLM_RTK_AI.Pick> picks = RLM_RTK_AI.suggestProducts(account.Id, new List<RLM_RTK_AI.Option>{
            new RLM_RTK_AI.Option('RTK-TERMITE', 'Termite Plan', 'Termite monitoring and treatment'),
            new RLM_RTK_AI.Option('RTK-MOSQUITO', 'Seasonal Mosquito Plan', null)
        }, 'service plans');

        Assert.areEqual(1, picks.size());
        Assert.areEqual('RTK-TERMITE', picks[0].sku);
        Assert.areEqual('Mud tubes on the garage wall', picks[0].reason);
        Assert.isTrue(((String) generator.lastInputs.get('Context')).contains('RTK-MOSQUITO | Seasonal Mosquito Plan'));
    }

    @IsTest
    static void productSuggestionsAreEmptyWithoutEinstein() {
        stub();
        Account account = customer();
        finding(inspectionFor(account.Id), 'Garage', 'Other', null, 'Mud tubes');
        Assert.isTrue(RLM_RTK_AI.suggestProducts(account.Id, new List<RLM_RTK_AI.Option>{
            new RLM_RTK_AI.Option('RTK-TERMITE', 'Termite Plan', null) }, 'service plans').isEmpty());
    }

    @IsTest
    static void summaryIsSavedAndSentOnce() {
        stub();
        Account account = customer();
        Id inspectionId = inspectionFor(account.Id);
        RLM_RTK_Finding__c f = finding(inspectionId, 'Garage', 'Rodents', 'Entry Point', null);
        update new RLM_RTK_Finding__c(Id = f.Id, Treatment_Status__c = 'Treated');
        WorkOrder wo = new WorkOrder(AccountId = account.Id, Subject = 'Treatment', RLM_RTK_Inspection__c = inspectionId,
            Status = 'Completed');
        insert wo;

        RLM_RTK_AI.Summary summary = RLM_RTK_AI.summarizeVisit(wo.Id);

        Assert.isFalse(summary.aiGenerated);
        Assert.isTrue(summary.text.startsWith('Hi Dana,'), summary.text);
        Assert.isTrue(summary.text.contains('- Garage: rodents, entry point (moderate)'), summary.text);
        Assert.isTrue(summary.emailedTo == 'dana@example.com' || summary.emailError != null);
        WorkOrder saved = [SELECT RLM_RTK_Visit_Summary__c, RLM_RTK_Summary_Sent_At__c FROM WorkOrder WHERE Id = :wo.Id];
        Assert.areEqual(summary.text, saved.RLM_RTK_Visit_Summary__c);
        if (summary.emailedTo != null) {
            Assert.isNotNull(saved.RLM_RTK_Summary_Sent_At__c);
            Assert.areEqual(summary.text, RLM_RTK_AI.summarizeVisit(wo.Id).text, 'A sent summary is not rewritten');
        }
    }

    @IsTest
    static void summaryWaitsForTheVisitToBeComplete() {
        stub();
        WorkOrder wo = new WorkOrder(AccountId = customer().Id, Subject = 'Treatment');
        insert wo;
        try {
            RLM_RTK_AI.summarizeVisit(wo.Id);
            Assert.fail('Expected an error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Complete the visit'));
        }
    }

    @IsTest
    static void ruleExplanationWithoutFindings() {
        Assert.isTrue(RLM_RTK_AI.ruleExplanation(null).contains('Essential Pest Plan'));
    }

    @IsTest
    static void suggestionsThatAdmitNoEvidenceAreDropped() {
        Assert.isTrue(RLM_RTK_AI.isUnsupported('No bed bug activity reported, treatment not needed.'));
        Assert.isTrue(RLM_RTK_AI.isUnsupported('Potential entry points for rodents.'));
        Assert.isFalse(RLM_RTK_AI.isUnsupported('Mud tubes on the garage wall'));
    }

    @IsTest
    static void suggestionsMustTreatThePestTheyName() {
        RLM_RTK_AI.Option termite = new RLM_RTK_AI.Option('RTK-TERMITE', 'Termite Plan', 'Ongoing termite monitoring and treatment plan.');
        Assert.isFalse(RLM_RTK_AI.covers(termite, 'Live activity of ants in the exterior perimeter.'));
        Assert.isTrue(RLM_RTK_AI.covers(termite, 'Mud tubes on the garage wall'));
        Assert.isTrue(RLM_RTK_AI.covers(termite, 'Soft wood near the sill'));
    }
}

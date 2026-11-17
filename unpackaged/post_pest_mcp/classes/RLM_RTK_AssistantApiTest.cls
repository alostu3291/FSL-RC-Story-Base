@IsTest
private class RLM_RTK_AssistantApiTest {
    private static Map<String, Object> post(String operation, Map<String, Object> params) {
        RestRequest request = new RestRequest();
        request.requestURI = '/services/apexrest/verdant/assistant';
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'operation' => operation, 'params' => params }));
        RestContext.request = request;
        RestContext.response = new RestResponse();
        RLM_RTK_AssistantApi.handle();
        Assert.areEqual(200, RestContext.response.statusCode);
        return (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
    }

    private static Object ok(String operation, Map<String, Object> params) {
        Map<String, Object> response = post(operation, params);
        Assert.isTrue((Boolean) response.get('success'), 'Refused: ' + response.get('error'));
        return response.get('result');
    }

    private static String refused(String operation, Map<String, Object> params) {
        Map<String, Object> response = post(operation, params);
        Assert.isFalse((Boolean) response.get('success'), 'Expected ' + operation + ' to be refused');
        return (String) response.get('error');
    }

    private static WorkOrder inspectionVisit() {
        Account account = new Account(Name = 'Assistant Api Test', ShippingStreet = '142 Lakeview Ct',
            ShippingCity = 'Bloomingdale', ShippingState = 'IL', ShippingPostalCode = '60108');
        insert account;
        WorkOrder wo = new WorkOrder(AccountId = account.Id, Subject = 'Free Pest Inspection');
        insert wo;
        return wo;
    }

    @IsTest
    static void unknownOperationsAndMissingParamsComeBackAsErrors() {
        Assert.areEqual('Unknown operation teleport.', refused('teleport', null));
        Assert.areEqual('Missing recordId.', refused('visitContext', new Map<String, Object>()));
        Assert.isTrue(refused('schedule', new Map<String, Object>{ 'day' => 'someday' }).length() > 0);
    }

    @IsTest
    static void startingAnInspectionVisitOpensTheInspection() {
        WorkOrder wo = inspectionVisit();

        Map<String, Object> started = (Map<String, Object>) ok('startVisit', new Map<String, Object>{ 'recordId' => wo.Id });

        Id inspectionId = (Id) started.get('inspectionId');
        Assert.isNotNull(inspectionId);
        Assert.areEqual('walk', ((Map<String, Object>) started.get('context')).get('stage'));
        Assert.areEqual(inspectionId, [SELECT RLM_RTK_Inspection__c FROM WorkOrder WHERE Id = :wo.Id].RLM_RTK_Inspection__c);

        ServiceAppointment sa = new ServiceAppointment(ParentRecordId = wo.Id, EarliestStartTime = Datetime.now(),
            DueDate = Datetime.now().addDays(1));
        insert sa;
        Map<String, Object> state = (Map<String, Object>) ok('recordFinding', new Map<String, Object>{
            'recordId' => sa.Id, 'zone' => 'Kitchen', 'pest' => 'Ants', 'evidence' => 'Live Activity',
            'severity' => 'Moderate', 'customerNote' => 'Ant trail along the sink.'
        });
        Assert.areEqual(1, ((List<Object>) state.get('findings')).size());
        Map<String, Object> again = (Map<String, Object>) ok('inspection', new Map<String, Object>{ 'inspectionId' => inspectionId });
        Assert.areEqual(1, ((List<Object>) again.get('findings')).size());
    }

    @IsTest
    static void findingsNeedAStartedVisit() {
        WorkOrder wo = inspectionVisit();
        Assert.isTrue(refused('recordFinding', new Map<String, Object>{ 'workOrderId' => wo.Id, 'zone' => 'Kitchen' })
            .contains('Start the visit'));
    }

    @IsTest
    static void signingNeedsAProposalAndAnApproval() {
        WorkOrder wo = inspectionVisit();
        Opportunity opportunity = new Opportunity(Name = 'Assistant Api Opp', StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30), AccountId = wo.AccountId);
        insert opportunity;
        Quote q = new Quote(Name = 'Assistant Api Quote', OpportunityId = opportunity.Id, Pricebook2Id = Test.getStandardPricebookId());
        insert q;

        Map<String, Object> details = (Map<String, Object>) ok('quote', new Map<String, Object>{ 'quoteId' => q.Id });
        Assert.areEqual('Assistant Api Quote', details.get('name'));
        Assert.areEqual('Missing approvalStatement.',
            refused('acceptQuote', new Map<String, Object>{ 'quoteId' => q.Id, 'signerName' => 'Pat' }));
        Assert.isTrue(refused('acceptQuote', new Map<String, Object>{
            'quoteId' => q.Id, 'signerName' => 'Pat', 'approvalStatement' => 'Yes, go ahead.'
        }).contains('Generate the proposal'));
        Assert.isTrue(refused('placeOrder', new Map<String, Object>{ 'quoteId' => q.Id }).contains('not signed'));
    }

    @IsTest
    static void readsAndResetAnswerWithoutAnyDemoCustomers() {
        Assert.areEqual(0, ((List<Object>) ok('findCustomers', new Map<String, Object>{ 'search' => 'Nobody' })).size());
        Map<String, Object> reset = (Map<String, Object>) ok('resetDemo', new Map<String, Object>{ 'customerName' => 'Nobody' });
        Assert.areEqual(0, ((List<Object>) reset.get('archived')).size());
        Assert.isTrue(refused('resetDemo', new Map<String, Object>()).contains('customerName'));
    }

    @IsTest
    static void everyOperationAnswersWithTheEnvelope() {
        WorkOrder wo = inspectionVisit();
        Map<String, Object> params = new Map<String, Object>{
            'recordId' => wo.Id, 'workOrderId' => wo.Id, 'accountId' => wo.AccountId, 'appointmentId' => wo.Id,
            'quoteId' => wo.Id, 'processId' => wo.Id, 'findingId' => wo.Id, 'inspectionId' => wo.Id,
            'name' => 'Api Caller', 'street' => '1 Test St', 'pest' => 'Ants', 'postalCode' => '60108',
            'planSku' => 'RTK-ESSENTIAL', 'squareFootage' => 'Under2000', 'severity' => 'Light',
            'startTime' => '2030-01-01T16:00:00.000Z', 'status' => 'Treated', 'skus' => new List<Object>{ 'RTK-X' },
            'sku' => 'RTK-X', 'approvedBy' => 'Pat', 'fileName' => 'a.jpg', 'base64Data' => 'AAAA',
            'search' => 'Api', 'accountName' => 'Api Caller', 'amount' => 10, 'day' => '2030-01-01', 'hour' => 10
        };
        for (String operation : new List<String>{
            'bookInspection', 'bookReservice', 'schedule', 'customerSummary', 'visitBrief', 'visitContext', 'attachPhoto',
            'inspection', 'pricing', 'createQuote', 'startProposal', 'proposalStatus', 'orderStatus', 'treatmentSlots',
            'bookTreatment', 'recordTreatment', 'addOnOptions', 'addAddOns', 'planOptions', 'changePlan', 'completeVisit',
            'visitSummary', 'explainBill'
        }) {
            Map<String, Object> response = post(operation, params);
            Assert.isTrue(response.get('success') instanceof Boolean, operation + ' answered without the envelope');
        }
    }

    @IsTest
    static void paramsAcceptWhatAnAssistantSends() {
        RLM_RTK_AssistantApi.Params p = new RLM_RTK_AssistantApi.Params(new Map<String, Object>{
            'list' => new List<Object>{ 'RTK-A', 'RTK-B' },
            'csv' => 'RTK-A, RTK-B,',
            'flag' => 'true',
            'hour' => 14.0,
            'amount' => '$1,402.60',
            'day' => '2026-11-19T00:00:00Z',
            'at' => '2026-11-19T16:00:00.000Z'
        });

        Assert.areEqual(new List<String>{ 'RTK-A', 'RTK-B' }, p.strings('list'));
        Assert.areEqual(new List<String>{ 'RTK-A', 'RTK-B' }, p.strings('csv'));
        Assert.isTrue(p.bool('flag'));
        Assert.isFalse(p.bool('missing'));
        Assert.areEqual(14, p.integerValue('hour'));
        Assert.areEqual(1402.60, p.decimalValue('amount'));
        Assert.areEqual(Date.newInstance(2026, 11, 19), p.dateValue('day'));
        Assert.areEqual(Datetime.newInstanceGmt(2026, 11, 19, 16, 0, 0), p.datetimeValue('at'));
    }
}

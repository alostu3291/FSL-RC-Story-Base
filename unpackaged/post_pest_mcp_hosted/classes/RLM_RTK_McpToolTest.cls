@IsTest
private class RLM_RTK_McpToolTest {
    @IsTest
    static void daysResolveInCentralTime() {
        Date today = RLM_RTK_McpTool.todayCentral();
        Assert.areEqual(String.valueOf(today), RLM_RTK_McpTool.isoDay('Today'));
        Assert.areEqual(String.valueOf(today.addDays(1)), RLM_RTK_McpTool.isoDay(' tomorrow '));
        Assert.areEqual('2026-11-18', RLM_RTK_McpTool.isoDay('2026-11-18T10:00:00'));
        try {
            RLM_RTK_McpTool.isoDay('someday');
            Assert.fail('Expected a refusal');
        } catch (RLM_RTK_McpTool.McpToolException e) {
            Assert.isTrue(e.getMessage().contains('someday'));
        }
    }

    @IsTest
    static void timestampsGainCentralLabels() {
        Assert.areEqual('Wed Nov 18, 4:00 PM Central', RLM_RTK_McpTool.localTime('2026-11-18T22:00:00.000Z'));
        Assert.isNull(RLM_RTK_McpTool.localTime('2026-11-18'));
        Assert.isNull(RLM_RTK_McpTool.localTime('Sarah Mitchell'));

        Map<String, Object> labelled = (Map<String, Object>) JSON.deserializeUntyped(RLM_RTK_McpTool.withLocalTimes(
            new Map<String, Object>{
                'visits' => new List<Object>{ new Map<String, Object>{ 'start' => '2026-11-18T15:00:00.000Z' } },
                'name' => 'Sarah'
            }));
        Map<String, Object> visit = (Map<String, Object>) ((List<Object>) labelled.get('visits'))[0];
        Assert.areEqual('Wed Nov 18, 9:00 AM Central', visit.get('startLocal'));
        Assert.isFalse(labelled.containsKey('nameLocal'));
    }

    @IsTest
    static void customersResolveByNameOrId() {
        Account sam = new Account(Name = 'Mcp Sam Patel');
        insert new List<Account>{ sam, new Account(Name = 'Mcp Sam Patel Jr'), new Account(Name = 'Mcp Dana Lee') };

        Assert.areEqual(sam.Id, RLM_RTK_McpTool.accountId('mcp sam patel'));
        Assert.areEqual(sam.Id, RLM_RTK_McpTool.accountId(sam.Id));
        Assert.areEqual([SELECT Id FROM Account WHERE Name = 'Mcp Dana Lee'].Id, RLM_RTK_McpTool.accountId('Dana'));
        assertRefused('Nobody Here', 'No customer');
        assertRefused('Mcp', 'Several customers');
    }

    private static void assertRefused(String customer, String expected) {
        try {
            RLM_RTK_McpTool.accountId(customer);
            Assert.fail('Expected a refusal for ' + customer);
        } catch (RLM_RTK_McpTool.McpToolException e) {
            Assert.isTrue(e.getMessage().startsWith(expected), e.getMessage());
        }
    }

    @IsTest
    static void refusalsComeBackAsErrorsNotExceptions() {
        RLM_RTK_McpTool.Response unknown = RLM_RTK_McpTool.call('teleport', new Map<String, Object>());
        Assert.isFalse(unknown.success);
        Assert.areEqual('Unknown operation teleport.', unknown.error);

        RLM_RTK_McpTool.Response badDay = RLM_RTK_McpTool.call('schedule', new Map<String, Object>{ 'day' => 'someday' });
        Assert.isFalse(badDay.success);
        Assert.isTrue(badDay.error.contains('someday'));
    }

    @IsTest
    static void scheduleDefaultsToTodayInCentralTime() {
        RLM_RTK_McpGetMySchedule.Request request = new RLM_RTK_McpGetMySchedule.Request();
        RLM_RTK_McpTool.Response response = RLM_RTK_McpGetMySchedule.run(new List<RLM_RTK_McpGetMySchedule.Request>{ request })[0];
        if (response.success != true) {
            Assert.isTrue(response.error.contains('territory'), 'Unexpected refusal: ' + response.error);
            return;
        }
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(response.result);
        Assert.areEqual(String.valueOf(RLM_RTK_McpTool.todayCentral()), result.get('day'));
        Assert.areEqual(result.get('day'), result.get('today'));
        Assert.isNotNull(result.get('visits'));
    }

    @IsTest
    static void findCustomerReturnsMatches() {
        insert new Account(Name = 'Mcp Finder Test');
        RLM_RTK_McpFindCustomer.Request request = new RLM_RTK_McpFindCustomer.Request();
        request.search = 'Mcp Finder';
        RLM_RTK_McpTool.Response response = RLM_RTK_McpFindCustomer.run(new List<RLM_RTK_McpFindCustomer.Request>{ request })[0];
        Assert.isTrue(response.success == true, 'Refused: ' + response.error);
        Assert.isNull(response.error);
        Assert.isTrue(response.result.contains('Mcp Finder Test'));
    }

    @IsTest
    static void everyToolAnswersWithoutThrowing() {
        List<RLM_RTK_McpTool.Response> responses = new List<RLM_RTK_McpTool.Response>();
        responses.addAll(RLM_RTK_McpBookInspection.run(new List<RLM_RTK_McpBookInspection.Request>{ new RLM_RTK_McpBookInspection.Request() }));
        responses.addAll(RLM_RTK_McpReportReservice.run(new List<RLM_RTK_McpReportReservice.Request>{ new RLM_RTK_McpReportReservice.Request() }));
        responses.addAll(RLM_RTK_McpGetVisitBrief.run(new List<RLM_RTK_McpGetVisitBrief.Request>{ new RLM_RTK_McpGetVisitBrief.Request() }));
        responses.addAll(RLM_RTK_McpGetCustomerSummary.run(new List<RLM_RTK_McpGetCustomerSummary.Request>{ new RLM_RTK_McpGetCustomerSummary.Request() }));
        responses.addAll(RLM_RTK_McpGetVisitStatus.run(new List<RLM_RTK_McpGetVisitStatus.Request>{ new RLM_RTK_McpGetVisitStatus.Request() }));
        responses.addAll(RLM_RTK_McpStartVisit.run(new List<RLM_RTK_McpStartVisit.Request>{ new RLM_RTK_McpStartVisit.Request() }));
        responses.addAll(RLM_RTK_McpRecordFinding.run(new List<RLM_RTK_McpRecordFinding.Request>{ new RLM_RTK_McpRecordFinding.Request() }));
        responses.addAll(RLM_RTK_McpGetInspection.run(new List<RLM_RTK_McpGetInspection.Request>{ new RLM_RTK_McpGetInspection.Request() }));
        responses.addAll(RLM_RTK_McpGetPlanPricing.run(new List<RLM_RTK_McpGetPlanPricing.Request>{ new RLM_RTK_McpGetPlanPricing.Request() }));
        responses.addAll(RLM_RTK_McpCreateQuote.run(new List<RLM_RTK_McpCreateQuote.Request>{ new RLM_RTK_McpCreateQuote.Request() }));
        responses.addAll(RLM_RTK_McpGetQuote.run(new List<RLM_RTK_McpGetQuote.Request>{ new RLM_RTK_McpGetQuote.Request() }));
        responses.addAll(RLM_RTK_McpGenerateProposal.run(new List<RLM_RTK_McpGenerateProposal.Request>{ new RLM_RTK_McpGenerateProposal.Request() }));
        responses.addAll(RLM_RTK_McpGetProposalStatus.run(new List<RLM_RTK_McpGetProposalStatus.Request>{ new RLM_RTK_McpGetProposalStatus.Request() }));
        responses.addAll(RLM_RTK_McpRecordAcceptance.run(new List<RLM_RTK_McpRecordAcceptance.Request>{ new RLM_RTK_McpRecordAcceptance.Request() }));
        responses.addAll(RLM_RTK_McpPlaceOrder.run(new List<RLM_RTK_McpPlaceOrder.Request>{ new RLM_RTK_McpPlaceOrder.Request() }));
        responses.addAll(RLM_RTK_McpGetOrderStatus.run(new List<RLM_RTK_McpGetOrderStatus.Request>{ new RLM_RTK_McpGetOrderStatus.Request() }));
        responses.addAll(RLM_RTK_McpFindTreatmentSlots.run(new List<RLM_RTK_McpFindTreatmentSlots.Request>{ new RLM_RTK_McpFindTreatmentSlots.Request() }));
        responses.addAll(RLM_RTK_McpBookTreatment.run(new List<RLM_RTK_McpBookTreatment.Request>{ new RLM_RTK_McpBookTreatment.Request() }));
        responses.addAll(RLM_RTK_McpGetTreatmentChecklist.run(new List<RLM_RTK_McpGetTreatmentChecklist.Request>{ new RLM_RTK_McpGetTreatmentChecklist.Request() }));
        responses.addAll(RLM_RTK_McpRecordTreatment.run(new List<RLM_RTK_McpRecordTreatment.Request>{ new RLM_RTK_McpRecordTreatment.Request() }));
        responses.addAll(RLM_RTK_McpGetAddOnOptions.run(new List<RLM_RTK_McpGetAddOnOptions.Request>{ new RLM_RTK_McpGetAddOnOptions.Request() }));
        responses.addAll(RLM_RTK_McpAddAddOns.run(new List<RLM_RTK_McpAddAddOns.Request>{ new RLM_RTK_McpAddAddOns.Request() }));
        responses.addAll(RLM_RTK_McpGetPlanOptions.run(new List<RLM_RTK_McpGetPlanOptions.Request>{ new RLM_RTK_McpGetPlanOptions.Request() }));
        responses.addAll(RLM_RTK_McpChangePlan.run(new List<RLM_RTK_McpChangePlan.Request>{ new RLM_RTK_McpChangePlan.Request() }));
        responses.addAll(RLM_RTK_McpCompleteVisit.run(new List<RLM_RTK_McpCompleteVisit.Request>{ new RLM_RTK_McpCompleteVisit.Request() }));
        responses.addAll(RLM_RTK_McpSendVisitSummary.run(new List<RLM_RTK_McpSendVisitSummary.Request>{ new RLM_RTK_McpSendVisitSummary.Request() }));
        responses.addAll(RLM_RTK_McpExplainBill.run(new List<RLM_RTK_McpExplainBill.Request>{ new RLM_RTK_McpExplainBill.Request() }));

        Assert.areEqual(27, responses.size());
        for (RLM_RTK_McpTool.Response response : responses) {
            Assert.isTrue(response.success == true || String.isNotBlank(response.error), 'A refusal needs a reason');
        }
    }
}

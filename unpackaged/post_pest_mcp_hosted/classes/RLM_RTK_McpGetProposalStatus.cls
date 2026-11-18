/** Verdant hosted MCP tool get_proposal_status. */
public with sharing class RLM_RTK_McpGetProposalStatus {
    public class Request {
        @InvocableVariable(label='Quote Id' description='The quote Id from create_quote.' required=true)
        public String quoteId;
        @InvocableVariable(label='Process Id' description='The processId generate_proposal returned.' required=true)
        public String processId;
    }

    @InvocableMethod(label='Verdant: Get proposal status' description='Checks on a proposal that was still generating.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'quoteId' => r.quoteId, 'processId' => r.processId });
        }
        return RLM_RTK_McpTool.callEach('proposalStatus', params);
    }
}

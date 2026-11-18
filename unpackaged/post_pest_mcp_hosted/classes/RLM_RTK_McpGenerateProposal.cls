/** Verdant hosted MCP tool generate_proposal. */
public with sharing class RLM_RTK_McpGenerateProposal {
    public class Request {
        @InvocableVariable(label='Quote Id' description='The quote Id from create_quote.' required=true)
        public String quoteId;
    }

    @InvocableMethod(label='Verdant: Generate proposal' description='Starts generating the Verdant proposal PDF for the quote and returns right away. If status is Generating, call get_proposal_status with the quoteId and processId about every 15 seconds until it isn\'t (usually under a minute).' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'quoteId' => r.quoteId });
        }
        return RLM_RTK_McpTool.callEach('startProposal', params);
    }
}

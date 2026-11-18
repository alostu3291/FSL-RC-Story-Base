/** Verdant hosted MCP tool get_quote. */
public with sharing class RLM_RTK_McpGetQuote {
    public class Request {
        @InvocableVariable(label='Quote Id' description='The quote Id from create_quote.' required=true)
        public String quoteId;
    }

    @InvocableMethod(label='Verdant: Get quote' description='The quote\'s lines, monthly and one-time totals, plan explanation, signature and proposal.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'quoteId' => r.quoteId });
        }
        return RLM_RTK_McpTool.callEach('quote', params);
    }
}

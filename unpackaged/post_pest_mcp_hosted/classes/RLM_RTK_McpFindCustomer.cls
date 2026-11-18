/** Verdant hosted MCP tool find_customer. */
public with sharing class RLM_RTK_McpFindCustomer {
    public class Request {
        @InvocableVariable(label='Search' description='Part of the customer\'s name.' required=true)
        public String search;
    }

    @InvocableMethod(label='Verdant: Find customer' description='Finds customers by name, with their address and whether they have a plan.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'search' => r.search });
        }
        return RLM_RTK_McpTool.callEach('findCustomers', params);
    }
}

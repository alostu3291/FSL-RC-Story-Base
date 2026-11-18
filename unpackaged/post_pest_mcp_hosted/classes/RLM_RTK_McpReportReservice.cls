/** Verdant hosted MCP tool report_reservice. */
public with sharing class RLM_RTK_McpReportReservice {
    public class Request {
        @InvocableVariable(label='Customer' description='Customer name as it appears in Salesforce (for example Sam Patel) or an Account Id.' required=true)
        public String customer;
        @InvocableVariable(label='Pest' description='One of: Ants, Spiders, Cockroaches, Rodents, Termites, Mosquitoes, Wasps / Bees, Bed Bugs, Other.' required=true)
        public String pest;
        @InvocableVariable(label='Description' description='What the customer reports, in their words.' required=true)
        public String description;
        @InvocableVariable(label='Day' description='Day as YYYY-MM-DD, or today / tomorrow. Central time.')
        public String day;
        @InvocableVariable(label='Hour' description='Start hour on the 24-hour clock, Central time (for example 10 or 14).')
        public Integer hour;
    }

    @InvocableMethod(label='Verdant: Report re-service' description='Books a Pest Re-service for an existing customer who reports pests between visits. Salesforce decides coverage from the customer\'s guarantees: a Covered re-service is free and gets a response deadline; a Not Covered one is billable. Tell the customer which it is.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'customer' => r.customer, 'pest' => r.pest, 'description' => r.description, 'day' => r.day, 'hour' => r.hour });
        }
        return RLM_RTK_McpTool.callEach('bookReservice', params);
    }
}

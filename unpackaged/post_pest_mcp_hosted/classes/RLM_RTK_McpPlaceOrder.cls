/** Verdant hosted MCP tool place_order. */
public with sharing class RLM_RTK_McpPlaceOrder {
    public class Request {
        @InvocableVariable(label='Quote Id' description='The quote Id from create_quote.' required=true)
        public String quoteId;
    }

    @InvocableMethod(label='Verdant: Place order' description='Turns the signed quote into an activated order and returns right away. Fulfillment then creates the Initial Pest Treatment visit: call get_order_status about every 15 seconds until it returns a treatmentAppointmentId (up to about 2 minutes), then offer treatment slots.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'quoteId' => r.quoteId });
        }
        return RLM_RTK_McpTool.callEach('placeOrder', params);
    }
}

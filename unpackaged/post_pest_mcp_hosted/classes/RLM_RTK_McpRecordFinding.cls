/** Verdant hosted MCP tool record_finding. */
public with sharing class RLM_RTK_McpRecordFinding {
    public class Request {
        @InvocableVariable(label='Visit' description='The visit: a work order Id or service appointment Id from get_my_schedule.' required=true)
        public String visit;
        @InvocableVariable(label='Zone' description='One of: Exterior Perimeter, Garage, Kitchen, Bathrooms, Living Areas, Basement / Crawlspace, Attic, Yard.' required=true)
        public String zone;
        @InvocableVariable(label='Pest' description='One of: Ants, Spiders, Cockroaches, Rodents, Termites, Mosquitoes, Wasps / Bees, Bed Bugs, Other.' required=true)
        public String pest;
        @InvocableVariable(label='Evidence' description='One of: Live Activity, Droppings, Damage, Nest, Entry Point, Standing Water, Wood-to-Soil Contact, Moisture.' required=true)
        public String evidence;
        @InvocableVariable(label='Severity' description='One of: Light, Moderate, Heavy.' required=true)
        public String severity;
        @InvocableVariable(label='Customer Note' description='Plain-language note the customer sees on the proposal.' required=true)
        public String customerNote;
        @InvocableVariable(label='Internal Note' description='Technician-only note.')
        public String internalNote;
        @InvocableVariable(label='Finding Id' description='Pass to update an existing finding instead of adding one.')
        public String findingId;
    }

    @InvocableMethod(label='Verdant: Record finding' description='Records one inspection finding. Returns all findings plus Salesforce\'s plan recommendation.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'recordId' => r.visit, 'zone' => r.zone, 'pest' => r.pest, 'evidence' => r.evidence, 'severity' => r.severity, 'customerNote' => r.customerNote, 'internalNote' => r.internalNote, 'findingId' => r.findingId });
        }
        return RLM_RTK_McpTool.callEach('recordFinding', params);
    }
}

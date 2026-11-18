/** Verdant hosted MCP tool book_inspection_for_caller. */
public with sharing class RLM_RTK_McpBookInspection {
    public class Request {
        @InvocableVariable(label='Name' description='Caller\'s full name.' required=true)
        public String name;
        @InvocableVariable(label='Street' description='Street address of the property, for example 218 Maple Ridge Dr.' required=true)
        public String street;
        @InvocableVariable(label='Description' description='What the caller is seeing, in their words, for the technician.' required=true)
        public String description;
        @InvocableVariable(label='Day' description='Day as YYYY-MM-DD, or today / tomorrow. Central time.')
        public String day;
        @InvocableVariable(label='Hour' description='Start hour on the 24-hour clock, Central time (for example 10 or 14).')
        public Integer hour;
        @InvocableVariable(label='Phone' description='Caller\'s phone number.')
        public String phone;
        @InvocableVariable(label='Email' description='Caller\'s email address.')
        public String email;
        @InvocableVariable(label='City' description='Defaults to Bloomingdale.')
        public String city;
        @InvocableVariable(label='Postal Code' description='Defaults to 60108.')
        public String postalCode;
    }

    @InvocableMethod(label='Verdant: Book inspection for caller' description='Books a new caller\'s free Pest Inspection and dispatches it to the technician. Creates the customer and contact in Salesforce if they\'re new. Calling again for the same person moves the open inspection instead of booking a second one. Defaults to tomorrow at 10:00. Customers who already have a plan are refused; use report_reservice for them.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'name' => r.name, 'street' => r.street, 'description' => r.description, 'day' => r.day, 'hour' => r.hour, 'phone' => r.phone, 'email' => r.email, 'city' => r.city, 'postalCode' => r.postalCode });
        }
        return RLM_RTK_McpTool.callEach('bookInspection', params);
    }
}

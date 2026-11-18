/**
 * Shared plumbing for the Verdant tools on the hosted Salesforce MCP server (HXLXDO).
 * Each RLM_RTK_Mcp* invocable action is one tool; it hands its inputs to call(), which runs
 * the same RLM_RTK_AssistantApi operation the local Mac MCP server uses and returns text JSON.
 *
 * Inputs are normalised the way the local server did: a day may be today, tomorrow or
 * YYYY-MM-DD in Central time, and a customer may be a name or an Account Id. Every UTC
 * timestamp in a result gains a sibling <key>Local label in Central time, so the model never
 * converts time zones. Refusals come back as success=false with a plain-English error.
 */
public with sharing class RLM_RTK_McpTool {
    public static final String TIME_ZONE = 'America/Chicago';

    public class Response {
        @InvocableVariable(label='Success' description='True when the step ran. False means it was refused; read error.')
        public Boolean success;
        @InvocableVariable(label='Error' description='Why the step was refused, in words to relay to the user.')
        public String error;
        @InvocableVariable(label='Result' description='The result as JSON. Each timestamp has a matching ...Local field in Central time; quote those, never the UTC values.')
        public String result;
    }

    public class McpToolException extends Exception {}

    public static Response call(String operation, Map<String, Object> params) {
        Response response = new Response();
        try {
            Map<String, Object> values = normalise(params);
            if (operation == 'schedule' && !values.containsKey('day')) {
                values.put('day', String.valueOf(todayCentral()));
            }
            Object result = RLM_RTK_AssistantApi.run(operation, values);
            if (operation == 'schedule') {
                result = new Map<String, Object>{
                    'day' => values.get('day'),
                    'today' => String.valueOf(todayCentral()),
                    'visits' => result
                };
            }
            response.success = true;
            response.result = withLocalTimes(result);
        } catch (Exception e) {
            response.success = false;
            response.error = e.getMessage();
        }
        return response;
    }

    public static List<Response> callEach(String operation, List<Map<String, Object>> paramsList) {
        List<Response> responses = new List<Response>();
        for (Map<String, Object> params : paramsList) {
            responses.add(call(operation, params));
        }
        return responses;
    }

    private static Map<String, Object> normalise(Map<String, Object> params) {
        Map<String, Object> values = new Map<String, Object>();
        for (String key : params.keySet()) {
            Object value = params.get(key);
            if (value == null || (value instanceof String && String.isBlank((String) value))) {
                continue;
            }
            if (key == 'day') {
                value = isoDay((String) value);
            } else if (key == 'customer') {
                key = 'accountId';
                value = accountId((String) value);
            }
            values.put(key, value);
        }
        return values;
    }

    public static Date todayCentral() {
        return Date.valueOf(Datetime.now().format('yyyy-MM-dd', TIME_ZONE));
    }

    public static String isoDay(String value) {
        String day = value.trim().toLowerCase();
        if (day == 'today') {
            return String.valueOf(todayCentral());
        }
        if (day == 'tomorrow') {
            return String.valueOf(todayCentral().addDays(1));
        }
        try {
            return String.valueOf(Date.valueOf(day.left(10)));
        } catch (Exception e) {
            throw new McpToolException('Give the day as today, tomorrow or YYYY-MM-DD, not "' + value + '".');
        }
    }

    public static Id accountId(String customer) {
        String ref = customer.trim();
        if (ref.length() >= 15 && ref.startsWith('001')) {
            try {
                return Id.valueOf(ref);
            } catch (Exception e) {
                // Not an Id after all; search by name.
            }
        }
        List<RLM_RTK_Assistant.Match> matches = RLM_RTK_Assistant.findCustomers(ref);
        for (RLM_RTK_Assistant.Match m : matches) {
            if (m.name.equalsIgnoreCase(ref)) {
                return m.accountId;
            }
        }
        if (matches.size() == 1) {
            return matches[0].accountId;
        }
        if (matches.isEmpty()) {
            throw new McpToolException('No customer matches "' + ref + '".');
        }
        List<String> names = new List<String>();
        for (RLM_RTK_Assistant.Match m : matches) {
            names.add(m.name);
        }
        throw new McpToolException('Several customers match "' + ref + '": ' + String.join(names, ', ') + '. Say which one.');
    }

    public static String withLocalTimes(Object result) {
        return JSON.serialize(label(JSON.deserializeUntyped(JSON.serialize(result, true))));
    }

    private static Object label(Object node) {
        if (node instanceof Map<String, Object>) {
            Map<String, Object> source = (Map<String, Object>) node;
            Map<String, Object> labelled = new Map<String, Object>();
            for (String key : source.keySet()) {
                Object value = label(source.get(key));
                labelled.put(key, value);
                String local = value instanceof String ? localTime((String) value) : null;
                if (local != null && !source.containsKey(key + 'Local')) {
                    labelled.put(key + 'Local', local);
                }
            }
            return labelled;
        }
        if (node instanceof List<Object>) {
            List<Object> labelled = new List<Object>();
            for (Object item : (List<Object>) node) {
                labelled.add(label(item));
            }
            return labelled;
        }
        return node;
    }

    private static final Pattern UTC_TIMESTAMP = Pattern.compile('\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?Z');

    @TestVisible
    private static String localTime(String value) {
        if (!UTC_TIMESTAMP.matcher(value).matches()) {
            return null;
        }
        Datetime moment = (Datetime) JSON.deserialize('"' + value + '"', Datetime.class);
        return moment.format('EEE MMM d, h:mm a', TIME_ZONE) + ' Central';
    }
}

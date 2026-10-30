/**
 * Posts invoices for the billing schedules of Field Service driven orders once they are
 * ReadyForInvoicing. Billing schedules are released asynchronously (after a milestone is
 * accomplished or an order activates), so the job retries a few times before giving up.
 */
public with sharing class RLM_FSL_InvoiceOrder {
    @TestVisible
    private static final Integer MAX_ATTEMPTS = 5;
    private static final Integer RETRY_DELAY_MINUTES = 1;

    @InvocableMethod(label='Invoice Ready Billing Schedules' category='Field Service'
        description='Posts an invoice for the order billing schedules that are ready for invoicing.')
    public static void invoiceOrders(List<Id> orderIds) {
        enqueue(new Set<Id>(orderIds));
    }

    public static void enqueue(Set<Id> orderIds) {
        enqueue(orderIds, Date.today());
    }

    /** Invoices billing up to targetDate, so a change that starts on a later day gets its first bill. */
    public static void enqueue(Set<Id> orderIds, Date targetDate) {
        System.enqueueJob(new InvoiceJob(orderIds, 1, targetDate), RETRY_DELAY_MINUTES);
    }

    public class InvoiceJob implements Queueable {
        private final Set<Id> orderIds;
        private final Integer attempt;
        private final Date targetDate;

        public InvoiceJob(Set<Id> orderIds, Integer attempt) {
            this(orderIds, attempt, Date.today());
        }

        public InvoiceJob(Set<Id> orderIds, Integer attempt, Date targetDate) {
            this.orderIds = orderIds;
            this.attempt = attempt;
            this.targetDate = targetDate;
        }

        public void execute(QueueableContext context) {
            List<String> scheduleIds = readyScheduleIds(orderIds);
            if (scheduleIds.isEmpty()) {
                if (attempt < MAX_ATTEMPTS && !Test.isRunningTest()) {
                    System.enqueueJob(new InvoiceJob(orderIds, attempt + 1, targetDate), RETRY_DELAY_MINUTES);
                }
                return;
            }
            ConnectApi.RevenueAsyncRepresentation result = ConnectApi.Billing.generateInvoices(buildRequest(scheduleIds, targetDate));
            if (result.success != true) {
                System.debug(LoggingLevel.ERROR, 'Invoice generation failed for ' + orderIds + ': ' + JSON.serialize(result.errors));
            }
        }
    }

    @TestVisible
    private static List<String> readyScheduleIdsOverride;

    private static List<String> readyScheduleIds(Set<Id> orderIds) {
        if (readyScheduleIdsOverride != null) {
            return readyScheduleIdsOverride;
        }
        List<String> scheduleIds = new List<String>();
        for (BillingSchedule schedule : [SELECT Id FROM BillingSchedule
                WHERE ReferenceEntityId IN :orderIds AND Status = 'ReadyForInvoicing' LIMIT 200]) {
            scheduleIds.add(schedule.Id);
        }
        return scheduleIds;
    }

    @TestVisible
    private static ConnectApi.InvoiceInputRepresentation buildRequest(List<String> scheduleIds) {
        return buildRequest(scheduleIds, Date.today());
    }

    @TestVisible
    private static ConnectApi.InvoiceInputRepresentation buildRequest(List<String> scheduleIds, Date targetDate) {
        Date today = Date.today();
        ConnectApi.InvoiceInputRepresentation input = new ConnectApi.InvoiceInputRepresentation();
        input.action = ConnectApi.InvoiceAction.Posted;
        input.billingScheduleIds = scheduleIds;
        input.invoiceDate = String.valueOf(today);
        input.targetDate = String.valueOf(targetDate == null || targetDate < today ? today : targetDate);
        return input;
    }
}

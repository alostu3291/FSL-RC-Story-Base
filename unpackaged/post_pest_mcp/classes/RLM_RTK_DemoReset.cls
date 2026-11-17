/**
 * Resets the Verdant Field Assistant demo so the scripted caller can be booked again: archives the
 * accounts the assistant created for that name (Account.RLM_RTK_Demo_Run__c is set) and cancels their
 * open visits so they leave the technician's schedule. Orders, assets and invoices stay as history.
 */
public with sharing class RLM_RTK_DemoReset {
    public static final String ARCHIVE_PREFIX = 'zz Archived - ';
    private static final Set<String> CLOSED = new Set<String>{ 'Completed', 'Closed', 'Canceled', 'Cannot Complete' };

    public class Result {
        public List<String> archived = new List<String>();
        public Integer workOrdersCanceled = 0;
        public Integer appointmentsCanceled = 0;
        public List<String> problems = new List<String>();
    }

    public static Result reset(String customerName) {
        if (String.isBlank(customerName)) {
            throw new ResetException('Say which demo customer to reset.');
        }
        Result result = new Result();
        List<Account> accounts = [
            SELECT Id, Name FROM Account WHERE Name = :customerName.trim() AND RLM_RTK_Demo_Run__c != null
        ];
        if (accounts.isEmpty()) {
            return result;
        }
        Set<Id> accountIds = new Map<Id, Account>(accounts).keySet();

        List<WorkOrder> workOrders = [
            SELECT Id FROM WorkOrder WHERE AccountId IN :accountIds AND Status NOT IN :CLOSED
        ];
        Set<Id> workOrderIds = new Map<Id, WorkOrder>(workOrders).keySet();
        List<ServiceAppointment> appointments = [
            SELECT Id FROM ServiceAppointment WHERE ParentRecordId IN :workOrderIds AND Status NOT IN :CLOSED
        ];
        for (ServiceAppointment sa : appointments) {
            sa.Status = 'Canceled';
        }
        List<ServiceAppointment> rejected = new List<ServiceAppointment>();
        Database.SaveResult[] saved = Database.update(appointments, false);
        for (Integer i = 0; i < saved.size(); i++) {
            if (saved[i].isSuccess()) {
                result.appointmentsCanceled++;
            } else {
                rejected.add(new ServiceAppointment(Id = appointments[i].Id));
            }
        }
        // Appointments whose lifecycle doesn't allow Canceled are removed instead, so they leave the schedule.
        for (Database.DeleteResult deleted : Database.delete(rejected, false)) {
            if (deleted.isSuccess()) {
                result.appointmentsCanceled++;
            } else {
                result.problems.add('Appointment ' + deleted.getId() + ': ' + deleted.getErrors()[0].getMessage());
            }
        }

        for (WorkOrder wo : workOrders) {
            wo.Status = 'Canceled';
        }
        for (Database.SaveResult r : Database.update(workOrders, false)) {
            if (r.isSuccess()) {
                result.workOrdersCanceled++;
            } else {
                result.problems.add('Work order ' + r.getId() + ': ' + r.getErrors()[0].getMessage());
            }
        }

        String stamp = Datetime.now().format('MMM d h:mm a');
        for (Account a : accounts) {
            a.Name = (ARCHIVE_PREFIX + a.Name + ' (' + stamp + ')').left(255);
            result.archived.add(a.Name);
        }
        update accounts;
        return result;
    }

    public class ResetException extends Exception {}
}

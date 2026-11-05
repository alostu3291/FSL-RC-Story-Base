/**
 * Books a signed Brightline Commercial contract quote: records the customer's PO number, creates the
 * order, and activates it once it exists with the property group's addresses, accounts payable as the
 * bill-to contact and the facility director as the ship-to contact. Activation assetizes the lines,
 * and RLM_HVAC_CommercialCoverage gives each site its response entitlement and maintenance plan.
 * A quote with an approval level must be approved first.
 */
public with sharing class RLM_HVAC_ContractOrder {

    public class Status {
        @AuraEnabled public Id quoteId;
        @AuraEnabled public String quoteName;
        @AuraEnabled public String quoteStatus;
        @AuraEnabled public Boolean awaitingApproval = false;
        @AuraEnabled public String poNumber;
        @AuraEnabled public Id orderId;
        @AuraEnabled public String orderNumber;
        /** None, Creating, Draft or Activated. */
        @AuraEnabled public String orderStatus = 'None';
        @AuraEnabled public Integer contractAssets = 0;
        @AuraEnabled public Integer sitesCovered = 0;
        @AuraEnabled public Integer siteCount = 0;
        @AuraEnabled public Integer maintenancePlans = 0;
        @AuraEnabled public Integer unitsMaintained = 0;
        @AuraEnabled public Integer upcomingVisits = 0;
        @AuraEnabled public Date firstVisit;
    }

    @AuraEnabled
    public static Status status(Id quoteId) {
        try {
            return statusFor(quoteId, false);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static Status placeOrder(Id quoteId, String poNumber) {
        try {
            Status current = statusFor(quoteId, false);
            if (current.awaitingApproval) {
                throw new ContractException('The discount on ' + current.quoteName + ' needs approval before the order can be placed.');
            }
            if (String.isBlank(poNumber) && String.isBlank(current.poNumber)) {
                throw new ContractException('Enter the customer\'s PO number.');
            }
            if (String.isNotBlank(poNumber) && poNumber.trim() != current.poNumber) {
                update new Quote(Id = quoteId, RLM_HVAC_PO_Number__c = poNumber.trim());
            }
            if (current.orderId == null) {
                Invocable.Action action = Invocable.Action.createStandardAction('createOrdersFromQuote');
                action.setInvocationParameter('quoteId', String.valueOf(quoteId));
                Invocable.Action.Result result = action.invoke()[0];
                if (!result.isSuccess()) {
                    List<String> errors = new List<String>();
                    for (Invocable.Action.Error error : result.getErrors()) {
                        errors.add(error.getMessage());
                    }
                    throw new ContractException('Could not create the order: ' + String.join(errors, '; '));
                }
            }
            return statusFor(quoteId, true);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Reports the order and its coverage; activates a draft order when asked to. */
    public static Status statusFor(Id quoteId, Boolean activateDraft) {
        Quote q = [
            SELECT Id, Name, Status, QuoteAccountId, ContactId, RLM_Approval_Level__c, RLM_HVAC_PO_Number__c,
                RLM_Line_of_Business__c
            FROM Quote WHERE Id = :quoteId
        ];
        if (q.RLM_Line_of_Business__c != RLM_HVAC_CommercialPricing.LOB) {
            throw new ContractException('Book Contract is for Commercial HVAC contract quotes.');
        }
        Status s = new Status();
        s.quoteId = q.Id;
        s.quoteName = q.Name;
        s.quoteStatus = q.Status;
        s.poNumber = q.RLM_HVAC_PO_Number__c;
        s.awaitingApproval = q.RLM_Approval_Level__c != null && q.RLM_Approval_Level__c > 0
            && q.Status != 'Approved' && q.Status != 'Accepted';

        List<Order> orders = [
            SELECT Id, OrderNumber, Status, PoNumber FROM Order WHERE QuoteId = :quoteId ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (orders.isEmpty()) {
            if (activateDraft) {
                s.orderStatus = 'Creating';
            }
            return s;
        }
        Order o = orders[0];
        s.orderId = o.Id;
        s.orderNumber = o.OrderNumber;
        s.orderStatus = o.Status;
        if (activateDraft && o.Status == 'Draft') {
            activateOrder(o, q);
            s.orderStatus = 'Activated';
        }
        countCoverage(s, o.Id);
        return s;
    }

    private static void activateOrder(Order o, Quote q) {
        Account parent = [
            SELECT Id, Name, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry,
                (SELECT Id, Title FROM Contacts ORDER BY CreatedDate)
            FROM Account WHERE Id = :q.QuoteAccountId
        ];
        Id payables;
        for (Contact c : parent.Contacts) {
            if (c.Title != null && c.Title.containsIgnoreCase('Payable')) {
                payables = c.Id;
                break;
            }
        }
        Id facilities = q.ContactId != null ? q.ContactId : (parent.Contacts.isEmpty() ? null : parent.Contacts[0].Id);
        if (payables == null) {
            payables = facilities;
        }
        if (payables == null) {
            throw new ContractException('Add a contact to ' + parent.Name + ' before booking the contract.');
        }
        update new Order(
            Id = o.Id,
            PoNumber = q.RLM_HVAC_PO_Number__c,
            BillToContactId = payables,
            ShipToContactId = facilities,
            BillingStreet = parent.BillingStreet,
            BillingCity = parent.BillingCity,
            BillingState = parent.BillingState,
            BillingPostalCode = parent.BillingPostalCode,
            BillingCountry = parent.BillingCountry,
            ShippingStreet = parent.ShippingStreet ?? parent.BillingStreet,
            ShippingCity = parent.ShippingCity ?? parent.BillingCity,
            ShippingState = parent.ShippingState ?? parent.BillingState,
            ShippingPostalCode = parent.ShippingPostalCode ?? parent.BillingPostalCode,
            ShippingCountry = parent.ShippingCountry ?? parent.BillingCountry,
            Status = 'Activated'
        );
        update new Quote(Id = q.Id, Status = 'Accepted');
    }

    private static void countCoverage(Status s, Id orderId) {
        Set<Id> siteIds = new Set<Id>();
        for (OrderItem item : [SELECT RLM_HVAC_Site__c FROM OrderItem WHERE OrderId = :orderId AND RLM_HVAC_Site__c != null]) {
            siteIds.add(item.RLM_HVAC_Site__c);
        }
        s.siteCount = siteIds.size();
        Set<Id> assetIds = new Set<Id>();
        for (AssetActionSource source : [
            SELECT AssetAction.AssetId FROM AssetActionSource
            WHERE ReferenceEntityItemId IN (SELECT Id FROM OrderItem WHERE OrderId = :orderId)
        ]) {
            assetIds.add(source.AssetAction.AssetId);
        }
        s.contractAssets = assetIds.size();
        Set<Id> covered = new Set<Id>();
        for (Entitlement e : [SELECT AccountId FROM Entitlement WHERE AssetId IN :assetIds]) {
            covered.add(e.AccountId);
        }
        s.sitesCovered = covered.size();
        Set<Id> planIds = new Set<Id>();
        for (MaintenancePlan mp : [
            SELECT Id FROM MaintenancePlan
            WHERE AccountId IN :siteIds AND MaintenancePlanTitle = :RLM_HVAC_CommercialCoverage.PLAN_TITLE
        ]) {
            planIds.add(mp.Id);
        }
        s.maintenancePlans = planIds.size();
        s.unitsMaintained = [SELECT COUNT() FROM MaintenanceAsset WHERE MaintenancePlanId IN :planIds];
        for (WorkOrder wo : [
            SELECT SuggestedMaintenanceDate FROM WorkOrder
            WHERE MaintenancePlanId IN :planIds AND Status = 'New' ORDER BY SuggestedMaintenanceDate
        ]) {
            s.upcomingVisits++;
            if (s.firstVisit == null) {
                s.firstVisit = wo.SuggestedMaintenanceDate;
            }
        }
    }

    private static AuraHandledException auraError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }

    public class ContractException extends Exception {}
}

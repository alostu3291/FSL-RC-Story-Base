/**
 * Brightline Commercial refrigerant compliance.
 *
 * Each refrigerant addition is a Refrigerant Log. Its leak rate uses the EPA annualizing method:
 * pounds added / full charge x 365 / days since the previous addition (capped at 365). A unit that
 * holds 50 lb or more (Asset.RLM_HVAC_Leak_Rate_Tracked__c) and goes over the comfort cooling limit
 * is flagged Leak Repair Due with a 30-day deadline and gets a leak repair work order at its site.
 * Completing that work order puts the unit back In Compliance.
 */
public with sharing class RLM_HVAC_RefrigerantCompliance {
    /** Comfort cooling leak rate limit, percent a year. */
    public static final Decimal LEAK_LIMIT = 10;
    public static final Integer REPAIR_DAYS = 30;
    public static final String REPAIR_WORK_TYPE = 'Commercial Leak Repair';
    public static final String IN_COMPLIANCE = 'In Compliance';
    public static final String REPAIR_DUE = 'Leak Repair Due';

    public class LogEntry {
        @AuraEnabled public Id logId;
        @AuraEnabled public String name;
        @AuraEnabled public Date loggedOn;
        @AuraEnabled public Decimal pounds;
        @AuraEnabled public Decimal leakRate;
        @AuraEnabled public Boolean overLimit = false;
        @AuraEnabled public String technician;
        @AuraEnabled public String notes;
        @AuraEnabled public String repairWorkOrderNumber;
    }

    public class UnitState {
        @AuraEnabled public Id assetId;
        @AuraEnabled public String tag;
        @AuraEnabled public String model;
        @AuraEnabled public Decimal tons;
        @AuraEnabled public String refrigerant;
        @AuraEnabled public Decimal charge;
        @AuraEnabled public Boolean tracked = false;
        @AuraEnabled public Decimal leakRate;
        @AuraEnabled public Date lastAdded;
        @AuraEnabled public String status;
        @AuraEnabled public Date repairDue;
        @AuraEnabled public Id repairWorkOrderId;
        @AuraEnabled public String repairWorkOrderNumber;
        @AuraEnabled public List<LogEntry> logs = new List<LogEntry>();
    }

    public class State {
        @AuraEnabled public Id workOrderId;
        @AuraEnabled public String workOrderNumber;
        @AuraEnabled public Id siteId;
        @AuraEnabled public String siteName;
        @AuraEnabled public Decimal leakLimit = LEAK_LIMIT;
        @AuraEnabled public Boolean singleUnit = false;
        @AuraEnabled public List<UnitState> units = new List<UnitState>();
    }

    public class Result {
        @AuraEnabled public Id assetId;
        @AuraEnabled public String tag;
        @AuraEnabled public Decimal leakRate;
        @AuraEnabled public Integer days;
        @AuraEnabled public Boolean tracked = false;
        @AuraEnabled public Boolean overLimit = false;
        @AuraEnabled public Date repairDue;
        @AuraEnabled public String repairWorkOrderNumber;
        @AuraEnabled public State state;
    }

    // ---------------------------------------------------------------- screen

    /** recordId is a work order (the site's units) or an asset (that unit). */
    @AuraEnabled
    public static State state(Id recordId) {
        try {
            return stateFor(recordId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    public static State stateFor(Id recordId) {
        State s = new State();
        Id siteId;
        Id onlyAsset;
        if (recordId.getSObjectType() == Asset.SObjectType) {
            Asset a = [SELECT Id, AccountId, Account.Name FROM Asset WHERE Id = :recordId];
            siteId = a.AccountId;
            s.siteName = a.Account.Name;
            onlyAsset = a.Id;
            s.singleUnit = true;
        } else {
            WorkOrder wo = [SELECT Id, WorkOrderNumber, AccountId, Account.Name FROM WorkOrder WHERE Id = :recordId];
            s.workOrderId = wo.Id;
            s.workOrderNumber = wo.WorkOrderNumber;
            siteId = wo.AccountId;
            s.siteName = wo.Account.Name;
        }
        s.siteId = siteId;
        Map<Id, UnitState> byAsset = new Map<Id, UnitState>();
        for (Asset a : [
            SELECT Id, Name, RLM_HVAC_Unit_Tag__c, RLM_HVAC_Tonnage__c, RLM_HVAC_Refrigerant_Type__c,
                RLM_HVAC_Refrigerant_Charge__c, RLM_HVAC_Leak_Rate_Tracked__c, RLM_HVAC_Leak_Rate__c,
                RLM_HVAC_Last_Refrigerant_Add__c, RLM_HVAC_Compliance_Status__c, RLM_HVAC_Repair_Due_Date__c
            FROM Asset
            WHERE AccountId = :siteId AND RLM_HVAC_Tonnage__c != null AND Status != 'Obsolete'
            ORDER BY RLM_HVAC_Leak_Rate_Tracked__c DESC, RLM_HVAC_Unit_Tag__c
        ]) {
            if (onlyAsset != null && a.Id != onlyAsset) {
                continue;
            }
            UnitState u = new UnitState();
            u.assetId = a.Id;
            u.tag = a.RLM_HVAC_Unit_Tag__c;
            u.model = String.isBlank(a.RLM_HVAC_Unit_Tag__c) ? a.Name : a.Name.removeStart(a.RLM_HVAC_Unit_Tag__c).trim();
            u.tons = a.RLM_HVAC_Tonnage__c;
            u.refrigerant = a.RLM_HVAC_Refrigerant_Type__c;
            u.charge = a.RLM_HVAC_Refrigerant_Charge__c;
            u.tracked = a.RLM_HVAC_Leak_Rate_Tracked__c;
            u.leakRate = a.RLM_HVAC_Leak_Rate__c;
            u.lastAdded = a.RLM_HVAC_Last_Refrigerant_Add__c;
            u.status = a.RLM_HVAC_Compliance_Status__c;
            u.repairDue = a.RLM_HVAC_Repair_Due_Date__c;
            byAsset.put(a.Id, u);
            s.units.add(u);
        }
        for (RLM_HVAC_Refrigerant_Log__c l : [
            SELECT Id, Name, RLM_HVAC_Asset__c, RLM_HVAC_Logged_On__c, RLM_HVAC_Pounds_Added__c, RLM_HVAC_Leak_Rate__c,
                RLM_HVAC_Over_Limit__c, RLM_HVAC_Technician__r.Name, RLM_HVAC_Notes__c,
                RLM_HVAC_Repair_Work_Order__c, RLM_HVAC_Repair_Work_Order__r.WorkOrderNumber,
                RLM_HVAC_Repair_Work_Order__r.Status
            FROM RLM_HVAC_Refrigerant_Log__c
            WHERE RLM_HVAC_Asset__c IN :byAsset.keySet()
            ORDER BY RLM_HVAC_Logged_On__c DESC, CreatedDate DESC
        ]) {
            UnitState u = byAsset.get(l.RLM_HVAC_Asset__c);
            LogEntry e = new LogEntry();
            e.logId = l.Id;
            e.name = l.Name;
            e.loggedOn = l.RLM_HVAC_Logged_On__c;
            e.pounds = l.RLM_HVAC_Pounds_Added__c;
            e.leakRate = l.RLM_HVAC_Leak_Rate__c;
            e.overLimit = l.RLM_HVAC_Over_Limit__c;
            e.technician = l.RLM_HVAC_Technician__r?.Name;
            e.notes = l.RLM_HVAC_Notes__c;
            e.repairWorkOrderNumber = l.RLM_HVAC_Repair_Work_Order__r?.WorkOrderNumber;
            u.logs.add(e);
            if (u.repairWorkOrderId == null && l.RLM_HVAC_Repair_Work_Order__c != null && u.status == REPAIR_DUE) {
                u.repairWorkOrderId = l.RLM_HVAC_Repair_Work_Order__c;
                u.repairWorkOrderNumber = l.RLM_HVAC_Repair_Work_Order__r.WorkOrderNumber;
            }
        }
        return s;
    }

    /** Logs refrigerant added to a unit on this work order and returns the leak rate it implies. */
    @AuraEnabled
    public static Result logRefrigerant(Id recordId, Id assetId, Decimal pounds, String notes) {
        try {
            return logFor(recordId, assetId, pounds, notes);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    public static Result logFor(Id recordId, Id assetId, Decimal pounds, String notes) {
        if (pounds == null || pounds <= 0) {
            throw new ComplianceException('Enter the pounds of refrigerant added.');
        }
        if (pounds > 500) {
            throw new ComplianceException('That is more refrigerant than a rooftop unit holds; check the amount.');
        }
        RLM_HVAC_Refrigerant_Log__c log = new RLM_HVAC_Refrigerant_Log__c(
            RLM_HVAC_Asset__c = assetId,
            RLM_HVAC_Pounds_Added__c = pounds,
            RLM_HVAC_Notes__c = String.isBlank(notes) ? null : notes.trim().abbreviate(255),
            RLM_HVAC_Work_Order__c = recordId != null && recordId.getSObjectType() == WorkOrder.SObjectType ? recordId : null
        );
        insert log;
        RLM_HVAC_Refrigerant_Log__c saved = [
            SELECT RLM_HVAC_Asset__r.RLM_HVAC_Unit_Tag__c, RLM_HVAC_Asset__r.RLM_HVAC_Leak_Rate_Tracked__c,
                RLM_HVAC_Asset__r.RLM_HVAC_Repair_Due_Date__c, RLM_HVAC_Leak_Rate__c, RLM_HVAC_Days_Since_Last__c,
                RLM_HVAC_Over_Limit__c, RLM_HVAC_Repair_Work_Order__r.WorkOrderNumber
            FROM RLM_HVAC_Refrigerant_Log__c WHERE Id = :log.Id
        ];
        Result r = new Result();
        r.assetId = assetId;
        r.tag = saved.RLM_HVAC_Asset__r.RLM_HVAC_Unit_Tag__c;
        r.leakRate = saved.RLM_HVAC_Leak_Rate__c;
        r.days = saved.RLM_HVAC_Days_Since_Last__c?.intValue();
        r.tracked = saved.RLM_HVAC_Asset__r.RLM_HVAC_Leak_Rate_Tracked__c;
        r.overLimit = saved.RLM_HVAC_Over_Limit__c;
        r.repairDue = saved.RLM_HVAC_Asset__r.RLM_HVAC_Repair_Due_Date__c;
        r.repairWorkOrderNumber = saved.RLM_HVAC_Repair_Work_Order__r?.WorkOrderNumber;
        r.state = stateFor(recordId != null ? recordId : assetId);
        return r;
    }

    // ---------------------------------------------------------------- leak rate

    /** Annualized leak rate in percent; days is the time since the previous addition, capped at 365. */
    public static Decimal leakRate(Decimal pounds, Decimal charge, Integer days) {
        if (charge == null || charge <= 0 || pounds == null) {
            return null;
        }
        Integer period = days == null || days > 365 ? 365 : Math.max(days, 1);
        return (pounds / charge * 365 / period * 100).setScale(1, System.RoundingMode.HALF_UP);
    }

    /** Before insert: fill the defaults and the leak rate from the unit's previous addition. */
    public static void logsInserting(List<RLM_HVAC_Refrigerant_Log__c> logs) {
        Set<Id> assetIds = new Set<Id>();
        for (RLM_HVAC_Refrigerant_Log__c l : logs) {
            if (l.RLM_HVAC_Logged_On__c == null) {
                l.RLM_HVAC_Logged_On__c = Date.today();
            }
            if (l.RLM_HVAC_Technician__c == null) {
                l.RLM_HVAC_Technician__c = UserInfo.getUserId();
            }
            assetIds.add(l.RLM_HVAC_Asset__c);
        }
        Map<Id, Asset> assets = new Map<Id, Asset>([
            SELECT Id, RLM_HVAC_Refrigerant_Charge__c, RLM_HVAC_Leak_Rate_Tracked__c FROM Asset WHERE Id IN :assetIds
        ]);
        Map<Id, List<Date>> previous = new Map<Id, List<Date>>();
        for (RLM_HVAC_Refrigerant_Log__c p : [
            SELECT RLM_HVAC_Asset__c, RLM_HVAC_Logged_On__c FROM RLM_HVAC_Refrigerant_Log__c
            WHERE RLM_HVAC_Asset__c IN :assetIds ORDER BY RLM_HVAC_Logged_On__c DESC
        ]) {
            if (!previous.containsKey(p.RLM_HVAC_Asset__c)) {
                previous.put(p.RLM_HVAC_Asset__c, new List<Date>());
            }
            previous.get(p.RLM_HVAC_Asset__c).add(p.RLM_HVAC_Logged_On__c);
        }
        for (RLM_HVAC_Refrigerant_Log__c l : logs) {
            Asset a = assets.get(l.RLM_HVAC_Asset__c);
            Date last;
            for (Date d : previous.get(l.RLM_HVAC_Asset__c) ?? new List<Date>()) {
                if (d <= l.RLM_HVAC_Logged_On__c) {
                    last = d;
                    break;
                }
            }
            Integer days = last == null ? 365 : Math.min(last.daysBetween(l.RLM_HVAC_Logged_On__c), 365);
            l.RLM_HVAC_Full_Charge__c = a.RLM_HVAC_Refrigerant_Charge__c;
            l.RLM_HVAC_Days_Since_Last__c = Math.max(days, 1);
            l.RLM_HVAC_Leak_Rate__c = leakRate(l.RLM_HVAC_Pounds_Added__c, a.RLM_HVAC_Refrigerant_Charge__c, days);
            l.RLM_HVAC_Leak_Limit__c = LEAK_LIMIT;
            l.RLM_HVAC_Over_Limit__c = a.RLM_HVAC_Leak_Rate_Tracked__c && l.RLM_HVAC_Leak_Rate__c != null
                && l.RLM_HVAC_Leak_Rate__c > LEAK_LIMIT;
        }
    }

    /** After insert: update each unit's leak rate and compliance, and open a repair for units over the limit. */
    public static void logsInserted(List<RLM_HVAC_Refrigerant_Log__c> logs) {
        Map<Id, RLM_HVAC_Refrigerant_Log__c> latest = new Map<Id, RLM_HVAC_Refrigerant_Log__c>();
        for (RLM_HVAC_Refrigerant_Log__c l : logs) {
            RLM_HVAC_Refrigerant_Log__c current = latest.get(l.RLM_HVAC_Asset__c);
            if (current == null || l.RLM_HVAC_Logged_On__c >= current.RLM_HVAC_Logged_On__c) {
                latest.put(l.RLM_HVAC_Asset__c, l);
            }
        }
        Map<Id, Asset> assets = new Map<Id, Asset>([
            SELECT Id, Name, AccountId, LocationId, RLM_HVAC_Unit_Tag__c, RLM_HVAC_Refrigerant_Charge__c,
                RLM_HVAC_Refrigerant_Type__c, RLM_HVAC_Leak_Rate_Tracked__c, RLM_HVAC_Compliance_Status__c,
                RLM_HVAC_Last_Refrigerant_Add__c, RLM_HVAC_Repair_Due_Date__c
            FROM Asset WHERE Id IN :latest.keySet()
        ]);
        Map<Id, WorkOrder> openRepairs = openRepairsFor(assets.keySet());
        List<Asset> updates = new List<Asset>();
        Map<Id, RLM_HVAC_Refrigerant_Log__c> needRepair = new Map<Id, RLM_HVAC_Refrigerant_Log__c>();
        for (RLM_HVAC_Refrigerant_Log__c l : latest.values()) {
            Asset a = assets.get(l.RLM_HVAC_Asset__c);
            if (a.RLM_HVAC_Last_Refrigerant_Add__c != null && a.RLM_HVAC_Last_Refrigerant_Add__c > l.RLM_HVAC_Logged_On__c) {
                continue;
            }
            Asset u = new Asset(Id = a.Id, RLM_HVAC_Leak_Rate__c = l.RLM_HVAC_Leak_Rate__c,
                RLM_HVAC_Last_Refrigerant_Add__c = l.RLM_HVAC_Logged_On__c);
            if (l.RLM_HVAC_Over_Limit__c) {
                u.RLM_HVAC_Compliance_Status__c = REPAIR_DUE;
                if (a.RLM_HVAC_Compliance_Status__c != REPAIR_DUE || a.RLM_HVAC_Repair_Due_Date__c == null) {
                    u.RLM_HVAC_Repair_Due_Date__c = l.RLM_HVAC_Logged_On__c.addDays(REPAIR_DAYS);
                }
                needRepair.put(a.Id, l);
            } else if (a.RLM_HVAC_Leak_Rate_Tracked__c && a.RLM_HVAC_Compliance_Status__c != REPAIR_DUE) {
                u.RLM_HVAC_Compliance_Status__c = IN_COMPLIANCE;
            }
            updates.add(u);
        }
        update updates;

        List<RLM_HVAC_Refrigerant_Log__c> links = new List<RLM_HVAC_Refrigerant_Log__c>();
        List<Asset> toRepair = new List<Asset>();
        for (Id assetId : needRepair.keySet()) {
            WorkOrder open = openRepairs.get(assetId);
            if (open != null) {
                links.add(new RLM_HVAC_Refrigerant_Log__c(Id = needRepair.get(assetId).Id, RLM_HVAC_Repair_Work_Order__c = open.Id));
            } else {
                toRepair.add(assets.get(assetId));
            }
        }
        if (!toRepair.isEmpty()) {
            Map<Id, WorkOrder> created = createRepairs(toRepair, needRepair);
            for (Id assetId : created.keySet()) {
                links.add(new RLM_HVAC_Refrigerant_Log__c(Id = needRepair.get(assetId).Id,
                    RLM_HVAC_Repair_Work_Order__c = created.get(assetId).Id));
            }
        }
        update links;
    }

    /** Open leak repair work orders by unit, from their lines. */
    private static Map<Id, WorkOrder> openRepairsFor(Set<Id> assetIds) {
        Map<Id, WorkOrder> byAsset = new Map<Id, WorkOrder>();
        for (WorkOrderLineItem line : [
            SELECT AssetId, WorkOrderId, WorkOrder.WorkOrderNumber FROM WorkOrderLineItem
            WHERE AssetId IN :assetIds AND WorkOrder.WorkType.Name = :REPAIR_WORK_TYPE
                AND WorkOrder.Status NOT IN ('Completed', 'Closed', 'Canceled', 'Cannot Complete')
        ]) {
            byAsset.put(line.AssetId, new WorkOrder(Id = line.WorkOrderId));
        }
        return byAsset;
    }

    private static Map<Id, WorkOrder> createRepairs(List<Asset> units, Map<Id, RLM_HVAC_Refrigerant_Log__c> logByAsset) {
        Set<Id> siteIds = new Set<Id>();
        for (Asset a : units) {
            siteIds.add(a.AccountId);
        }
        Map<Id, Account> sites = new Map<Id, Account>([
            SELECT Id, Name, ParentId, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry
            FROM Account WHERE Id IN :siteIds
        ]);
        Set<Id> groupIds = new Set<Id>();
        for (Account s : sites.values()) {
            groupIds.add(s.ParentId);
        }
        Map<Id, Id> contactByGroup = new Map<Id, Id>();
        for (Contact c : [SELECT Id, AccountId FROM Contact WHERE AccountId IN :groupIds AND Title LIKE '%Facilit%' ORDER BY CreatedDate]) {
            if (!contactByGroup.containsKey(c.AccountId)) {
                contactByGroup.put(c.AccountId, c.Id);
            }
        }
        Id workTypeId;
        for (WorkType wt : [SELECT Id FROM WorkType WHERE Name = :REPAIR_WORK_TYPE LIMIT 1]) {
            workTypeId = wt.Id;
        }
        Id territoryId;
        for (ServiceTerritory t : [SELECT Id FROM ServiceTerritory WHERE Name = :RLM_HVAC_CommercialCoverage.TERRITORY LIMIT 1]) {
            territoryId = t.Id;
        }
        Map<Id, WorkOrder> byAsset = new Map<Id, WorkOrder>();
        for (Asset a : units) {
            Account site = sites.get(a.AccountId);
            RLM_HVAC_Refrigerant_Log__c l = logByAsset.get(a.Id);
            String due = l.RLM_HVAC_Logged_On__c.addDays(REPAIR_DAYS).format();
            byAsset.put(a.Id, new WorkOrder(
                AccountId = site.Id,
                LocationId = a.LocationId,
                AssetId = a.Id,
                WorkTypeId = workTypeId,
                ServiceTerritoryId = territoryId,
                ContactId = contactByGroup.get(site.ParentId),
                Street = site.BillingStreet,
                City = site.BillingCity,
                State = site.BillingState,
                PostalCode = site.BillingPostalCode,
                Country = site.BillingCountry,
                Status = 'New',
                Priority = 'High',
                Subject = ('Leak repair: ' + a.RLM_HVAC_Unit_Tag__c + ' at ' + site.Name).left(255),
                Description = (a.RLM_HVAC_Unit_Tag__c + ' leaked at ' + l.RLM_HVAC_Leak_Rate__c.stripTrailingZeros().toPlainString()
                    + '% a year (' + l.RLM_HVAC_Pounds_Added__c.stripTrailingZeros().toPlainString() + ' lb of '
                    + a.RLM_HVAC_Refrigerant_Type__c + ' added, ' + a.RLM_HVAC_Refrigerant_Charge__c.stripTrailingZeros().toPlainString()
                    + ' lb charge), over the ' + LEAK_LIMIT.stripTrailingZeros().toPlainString()
                    + '% limit. Find and repair the leak, then run the initial and follow-up verification tests by ' + due + '.')
                    .abbreviate(32000)
            ));
        }
        insert byAsset.values();
        List<WorkOrderLineItem> lines = new List<WorkOrderLineItem>();
        for (Asset a : units) {
            lines.add(new WorkOrderLineItem(WorkOrderId = byAsset.get(a.Id).Id, AssetId = a.Id, WorkTypeId = workTypeId,
                Description = ('Leak search, repair and verification test on ' + a.RLM_HVAC_Unit_Tag__c).abbreviate(255)));
        }
        insert lines;
        return byAsset;
    }

    // ---------------------------------------------------------------- repair completion

    /** After update on Work Order: a completed leak repair puts its units back in compliance. */
    public static void workOrdersUpdated(List<WorkOrder> records, Map<Id, WorkOrder> oldMap) {
        Set<Id> completed = new Set<Id>();
        for (WorkOrder wo : records) {
            if (wo.Status == 'Completed' && oldMap.get(wo.Id).Status != 'Completed' && wo.WorkTypeId != null) {
                completed.add(wo.Id);
            }
        }
        if (completed.isEmpty()) {
            return;
        }
        Map<Id, Asset> updates = new Map<Id, Asset>();
        for (WorkOrderLineItem line : [
            SELECT AssetId FROM WorkOrderLineItem
            WHERE WorkOrderId IN :completed AND WorkOrder.WorkType.Name = :REPAIR_WORK_TYPE AND AssetId != null
                AND Asset.RLM_HVAC_Compliance_Status__c = :REPAIR_DUE
        ]) {
            updates.put(line.AssetId, new Asset(Id = line.AssetId, RLM_HVAC_Compliance_Status__c = IN_COMPLIANCE,
                RLM_HVAC_Repair_Due_Date__c = null));
        }
        update updates.values();
    }

    private static AuraHandledException auraError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }

    public class ComplianceException extends Exception {}
}

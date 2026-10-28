/**
 * Field Service coverage for Rentokil plans.
 *
 * When a customer's Initial Pest Treatment is completed, each active plan asset gets a guarantee
 * Entitlement listing the pests it covers, and the account gets one Maintenance Plan whose
 * per-asset rules set the recurring visits. Generation makes one Work Order per visit date with a
 * line per plan due that day, but leaves the work type, territory, address and contact blank, so
 * they are filled in here from the customer's earlier visits. The plan creates the visit's one
 * appointment, so the recurring visit work types must not auto-create appointments.
 *
 * A Pest Re-service Work Order is Covered when an active entitlement on the account lists the
 * reported pest, otherwise Not Covered, which RLM_FSL_Bill_Uncovered_Repair bills as RTK-RESERVICE
 * when the visit is completed.
 */
public with sharing class RLM_RTK_Coverage {
    public static final String PLAN_TITLE = 'Rentokil recurring service';
    public static final String INITIAL_TREATMENT = 'Initial Pest Treatment';
    public static final String RESERVICE = 'Pest Re-service';
    public static final String COVERED = 'Covered';
    public static final String NOT_COVERED = 'Not Covered';
    public static final String GENERATE_FLOW = 'RLM_RTK_Generate_Maintenance_Visits';

    public class Cadence {
        public final String workType;
        public final String recurrence;
        public final Integer months;
        public final Set<Integer> season;
        public final String pests;

        Cadence(String workType, String recurrence, Integer months, Set<Integer> season, String pests) {
            this.workType = workType;
            this.recurrence = recurrence;
            this.months = months;
            this.season = season;
            this.pests = pests;
        }

        public Date firstVisit(Date fromDate) {
            Date visit = fromDate.addMonths(months);
            while (season != null && !season.contains(visit.month())) {
                visit = visit.addMonths(1);
            }
            return visit;
        }
    }

    private static final String GENERAL = 'Ants;Spiders;Cockroaches';
    private static final Set<Integer> MOSQUITO_SEASON = new Set<Integer>{ 4, 5, 6, 7, 8, 9, 10 };

    /** Plan SKUs in the order their work type leads a combined visit. */
    @TestVisible
    private static final Map<String, Cadence> CADENCES = new Map<String, Cadence>{
        'RTK-HOME-PROT-PLUS' => new Cadence('Monthly Pest Visit', 'FREQ=MONTHLY;INTERVAL=1', 1, null,
            GENERAL + ';Rodents;Wasps / Bees;Other'),
        'RTK-HOME-PROT' => new Cadence('Monthly Pest Visit', 'FREQ=MONTHLY;INTERVAL=1', 1, null, GENERAL + ';Rodents'),
        'RTK-ESSENTIAL' => new Cadence('Quarterly Pest Visit', 'FREQ=MONTHLY;INTERVAL=3', 3, null, GENERAL),
        'RTK-MOSQUITO' => new Cadence('Mosquito Visit', 'FREQ=MONTHLY;BYMONTH=4,5,6,7,8,9,10', 1, MOSQUITO_SEASON,
            'Mosquitoes'),
        'RTK-TERMITE' => new Cadence('Termite Monitoring', 'FREQ=YEARLY;INTERVAL=1', 12, null, 'Termites')
    };

    private static Map<String, Id> workTypeIdsByName;

    @TestVisible
    private static Map<String, Id> workTypeIds() {
        if (workTypeIdsByName == null) {
            Set<String> names = new Set<String>{ INITIAL_TREATMENT, RESERVICE };
            for (Cadence c : CADENCES.values()) {
                names.add(c.workType);
            }
            workTypeIdsByName = new Map<String, Id>();
            for (WorkType wt : [SELECT Id, Name FROM WorkType WHERE Name IN :names]) {
                workTypeIdsByName.put(wt.Name, wt.Id);
            }
        }
        return workTypeIdsByName;
    }

    // ---------- Coverage when the plan starts ----------

    public class CoverageJob implements Queueable {
        private final Set<Id> accountIds;

        public CoverageJob(Set<Id> accountIds) {
            this.accountIds = accountIds;
        }

        public void execute(QueueableContext context) {
            generate(activate(accountIds));
        }
    }

    /**
     * Creates the missing guarantee entitlements, maintenance plan, maintenance assets and visit
     * rules for the accounts' active plans. Returns the plans that gained assets.
     */
    public static Set<Id> activate(Set<Id> accountIds) {
        Set<Id> changedPlans = new Set<Id>();
        List<Asset> assets = [
            SELECT Id, Name, AccountId, Product2.StockKeepingUnit, LifecycleStartDate, LifecycleEndDate
            FROM Asset
            WHERE AccountId IN :accountIds AND Product2.StockKeepingUnit IN :CADENCES.keySet()
                AND (CurrentQuantity > 0 OR HasLifecycleManagement = false)
            ORDER BY CreatedDate
        ];
        if (assets.isEmpty()) {
            return changedPlans;
        }
        createEntitlements(assets);

        Map<String, Id> workTypes = workTypeIds();
        Date today = Date.today();
        Map<Id, List<Asset>> assetsByAccount = new Map<Id, List<Asset>>();
        for (Asset a : assets) {
            if (!assetsByAccount.containsKey(a.AccountId)) {
                assetsByAccount.put(a.AccountId, new List<Asset>());
            }
            assetsByAccount.get(a.AccountId).add(a);
        }
        Map<Id, MaintenancePlan> planByAccount = new Map<Id, MaintenancePlan>();
        for (MaintenancePlan mp : [
            SELECT Id, AccountId FROM MaintenancePlan
            WHERE AccountId IN :assetsByAccount.keySet() AND MaintenancePlanTitle = :PLAN_TITLE
        ]) {
            planByAccount.put(mp.AccountId, mp);
        }
        List<MaintenancePlan> newPlans = new List<MaintenancePlan>();
        for (Id accountId : assetsByAccount.keySet()) {
            if (planByAccount.containsKey(accountId)) {
                continue;
            }
            Cadence lead;
            Date first;
            for (Asset a : assetsByAccount.get(accountId)) {
                Cadence c = CADENCES.get(a.Product2.StockKeepingUnit);
                lead = lead == null || leads(c, lead) ? c : lead;
                first = first == null || c.firstVisit(today) < first ? c.firstVisit(today) : first;
            }
            MaintenancePlan mp = new MaintenancePlan(
                AccountId = accountId,
                MaintenancePlanTitle = PLAN_TITLE,
                WorkTypeId = workTypes.get(lead.workType),
                StartDate = today,
                NextSuggestedMaintenanceDate = first,
                GenerationTimeframe = 4,
                GenerationTimeframeType = 'Months',
                DoesAutoGenerateWorkOrders = false,
                DoesGenerateUponCompletion = false,
                WorkOrderGenerationMethod = 'WorkOrderLineItemPerAsset',
                SvcApptGenerationMethod = 'SvcApptPerWorkOrder'
            );
            newPlans.add(mp);
            planByAccount.put(accountId, mp);
        }
        insert newPlans;

        Set<Id> maintained = new Set<Id>();
        for (MaintenanceAsset ma : [SELECT AssetId FROM MaintenanceAsset WHERE MaintenancePlanId IN :new Map<Id, MaintenancePlan>(planByAccount.values()).keySet()]) {
            maintained.add(ma.AssetId);
        }
        List<MaintenanceAsset> newAssets = new List<MaintenanceAsset>();
        List<Cadence> newCadences = new List<Cadence>();
        for (Asset a : assets) {
            if (maintained.add(a.Id)) {
                Cadence c = CADENCES.get(a.Product2.StockKeepingUnit);
                Id planId = planByAccount.get(a.AccountId).Id;
                newAssets.add(new MaintenanceAsset(
                    MaintenancePlanId = planId,
                    AssetId = a.Id,
                    WorkTypeId = workTypes.get(c.workType),
                    NextSuggestedMaintenanceDate = c.firstVisit(today)
                ));
                newCadences.add(c);
                changedPlans.add(planId);
            }
        }
        insert newAssets;

        List<MaintenanceWorkRule> rules = new List<MaintenanceWorkRule>();
        for (Integer i = 0; i < newAssets.size(); i++) {
            Cadence c = newCadences[i];
            rules.add(new MaintenanceWorkRule(
                ParentMaintenanceRecordId = newAssets[i].Id,
                Title = c.workType,
                WorkTypeId = workTypes.get(c.workType),
                Type = 'Calendar',
                SortOrder = 1,
                RecurrencePattern = c.recurrence,
                NextSuggestedMaintenanceDate = c.firstVisit(today)
            ));
        }
        insert rules;
        return changedPlans;
    }

    private static Boolean leads(Cadence candidate, Cadence current) {
        List<Cadence> order = CADENCES.values();
        return order.indexOf(candidate) < order.indexOf(current);
    }

    private static void createEntitlements(List<Asset> assets) {
        Set<Id> entitled = new Set<Id>();
        for (Entitlement e : [SELECT AssetId FROM Entitlement WHERE AssetId IN :assets]) {
            entitled.add(e.AssetId);
        }
        List<Entitlement> entitlements = new List<Entitlement>();
        for (Asset a : assets) {
            if (entitled.contains(a.Id)) {
                continue;
            }
            entitlements.add(new Entitlement(
                Name = (a.Name + ' guarantee').abbreviate(255),
                AccountId = a.AccountId,
                AssetId = a.Id,
                StartDate = a.LifecycleStartDate != null ? a.LifecycleStartDate.dateGmt() : Date.today(),
                EndDate = a.LifecycleEndDate != null ? a.LifecycleEndDate.dateGmt() : null,
                RLM_RTK_Covered_Pests__c = CADENCES.get(a.Product2.StockKeepingUnit).pests
            ));
        }
        insert entitlements;
    }

    /** Runs the standard Generate Work Orders action through a flow, which Apex can't call directly. */
    public static void generate(Set<Id> planIds) {
        for (Id planId : planIds) {
            try {
                Flow.Interview.createInterview(GENERATE_FLOW, new Map<String, Object>{ 'recordId' => planId }).start();
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Visit generation failed for ' + planId + ': ' + e.getMessage());
            }
        }
    }

    // ---------- Work Order trigger ----------

    public static void beforeSave(List<WorkOrder> records, Map<Id, WorkOrder> oldMap) {
        Map<String, Id> workTypes = workTypeIds();
        Id reservice = workTypes.get(RESERVICE);
        List<WorkOrder> visits = new List<WorkOrder>();
        List<WorkOrder> reservices = new List<WorkOrder>();
        for (WorkOrder wo : records) {
            if (wo.AccountId == null) {
                continue;
            }
            Boolean isReservice = reservice != null && wo.WorkTypeId == reservice;
            if (oldMap == null && (wo.MaintenancePlanId != null || isReservice)) {
                visits.add(wo);
            }
            if (isReservice && needsCoverageCheck(wo, oldMap == null ? null : oldMap.get(wo.Id))) {
                reservices.add(wo);
            }
        }
        if (!visits.isEmpty()) {
            fillVisitDefaults(visits);
        }
        if (!reservices.isEmpty()) {
            checkCoverage(reservices);
        }
    }

    public static void afterUpdate(List<WorkOrder> records, Map<Id, WorkOrder> oldMap) {
        Id initial = workTypeIds().get(INITIAL_TREATMENT);
        Set<Id> accountIds = new Set<Id>();
        for (WorkOrder wo : records) {
            if (initial != null && wo.WorkTypeId == initial && wo.AccountId != null && wo.Status == 'Completed'
                    && oldMap.get(wo.Id).Status != 'Completed') {
                accountIds.add(wo.AccountId);
            }
        }
        if (!accountIds.isEmpty() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new CoverageJob(accountIds));
        }
    }

    private static Boolean needsCoverageCheck(WorkOrder wo, WorkOrder old) {
        if (old == null) {
            return true;
        }
        if (wo.Status == 'Completed') {
            return false;
        }
        return wo.RLM_RTK_Reported_Pest__c != old.RLM_RTK_Reported_Pest__c || wo.AccountId != old.AccountId
            || wo.WorkTypeId != old.WorkTypeId || wo.RLM_Service_Coverage__c == null;
    }

    /** Copies territory, address and contact from the customer's latest visit, and links their accepted inspection. */
    @TestVisible
    private static void fillVisitDefaults(List<WorkOrder> visits) {
        Set<Id> accountIds = new Set<Id>();
        Set<Id> planIds = new Set<Id>();
        for (WorkOrder wo : visits) {
            accountIds.add(wo.AccountId);
            if (wo.MaintenancePlanId != null) {
                planIds.add(wo.MaintenancePlanId);
            }
        }
        Map<Id, MaintenancePlan> plans = new Map<Id, MaintenancePlan>(
            [SELECT Id, WorkTypeId FROM MaintenancePlan WHERE Id IN :planIds]
        );
        Map<Id, WorkOrder> latestByAccount = new Map<Id, WorkOrder>();
        for (WorkOrder past : [
            SELECT AccountId, ServiceTerritoryId, ContactId, Street, City, State, PostalCode, Country
            FROM WorkOrder
            WHERE AccountId IN :accountIds AND ServiceTerritoryId != null
            ORDER BY CreatedDate DESC
            LIMIT 500
        ]) {
            if (!latestByAccount.containsKey(past.AccountId)) {
                latestByAccount.put(past.AccountId, past);
            }
        }
        Map<Id, Id> inspectionByAccount = new Map<Id, Id>();
        for (RLM_RTK_Inspection__c inspection : [
            SELECT Id, Account__c FROM RLM_RTK_Inspection__c
            WHERE Account__c IN :accountIds AND Status__c = 'Accepted'
            ORDER BY CreatedDate DESC
            LIMIT 500
        ]) {
            if (!inspectionByAccount.containsKey(inspection.Account__c)) {
                inspectionByAccount.put(inspection.Account__c, inspection.Id);
            }
        }
        for (WorkOrder wo : visits) {
            WorkOrder latest = latestByAccount.get(wo.AccountId);
            if (latest != null && wo.ServiceTerritoryId == null) {
                wo.ServiceTerritoryId = latest.ServiceTerritoryId;
                if (String.isBlank(wo.Street)) {
                    wo.Street = latest.Street;
                    wo.City = latest.City;
                    wo.State = latest.State;
                    wo.PostalCode = latest.PostalCode;
                    wo.Country = latest.Country;
                }
            }
            if (latest != null && wo.ContactId == null) {
                wo.ContactId = latest.ContactId;
            }
            if (wo.RLM_RTK_Inspection__c == null) {
                wo.RLM_RTK_Inspection__c = inspectionByAccount.get(wo.AccountId);
            }
            MaintenancePlan plan = plans.get(wo.MaintenancePlanId);
            if (plan != null && wo.WorkTypeId == null) {
                wo.WorkTypeId = plan.WorkTypeId;
            }
        }
    }

    /** Covered when an active guarantee on the account lists the reported pest. */
    @TestVisible
    private static void checkCoverage(List<WorkOrder> reservices) {
        Set<Id> accountIds = new Set<Id>();
        for (WorkOrder wo : reservices) {
            accountIds.add(wo.AccountId);
        }
        Date today = Date.today();
        List<Entitlement> guarantees = [
            SELECT Id, AccountId, AssetId, RLM_RTK_Covered_Pests__c
            FROM Entitlement
            WHERE AccountId IN :accountIds AND RLM_RTK_Covered_Pests__c != null
                AND StartDate <= :today AND (EndDate = null OR EndDate >= :today)
            ORDER BY StartDate DESC
        ];
        for (WorkOrder wo : reservices) {
            if (String.isBlank(wo.RLM_RTK_Reported_Pest__c)) {
                wo.RLM_Service_Coverage__c = null;
                wo.EntitlementId = null;
                continue;
            }
            Entitlement match = coveringGuarantee(guarantees, wo.AccountId, wo.RLM_RTK_Reported_Pest__c);
            wo.RLM_Service_Coverage__c = match != null ? COVERED : NOT_COVERED;
            wo.EntitlementId = match?.Id;
            if (match != null && wo.AssetId == null) {
                wo.AssetId = match.AssetId;
            }
        }
    }

    private static Entitlement coveringGuarantee(List<Entitlement> guarantees, Id accountId, String pest) {
        for (Entitlement e : guarantees) {
            if (e.AccountId == accountId && e.RLM_RTK_Covered_Pests__c.split(';').contains(pest)) {
                return e;
            }
        }
        return null;
    }
}

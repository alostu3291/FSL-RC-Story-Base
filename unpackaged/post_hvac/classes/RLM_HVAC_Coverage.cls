/**
 * Field Service coverage for Brightline comfort agreements.
 *
 * When a customer's Initial Tune-up is completed, each active agreement asset gets an Entitlement
 * listing the systems it covers, and the account gets one Maintenance Plan whose per-asset rules set
 * the recurring visits: a spring AC tune-up in April and a fall furnace tune-up in October for every
 * agreement, quarterly filter visits for Indoor Air Quality and a yearly flush for Water Heater Care.
 * Generation makes one Work Order per visit date with a line per agreement due that day, but leaves
 * the territory, address and contact blank, so they are filled in here from the customer's earlier
 * visits, and the seasonal visit takes the spring or fall work type from its month. The plan creates
 * the visit's one appointment, so the recurring visit work types must not auto-create appointments.
 *
 * Coverage follows the agreement through upgrades, downgrades, pauses, renewals and cancellations.
 * The assets' state periods are the record of each change, so a sync rebuilds coverage from them: an
 * entitlement per active stretch of an agreement asset, upcoming visits only for agreements active
 * that day, and a visit rule per running agreement. Agreement asset changes sync their customers right
 * away (RLM_HVAC_AssetTrigger), and RLM_HVAC_Nightly_Coverage_Sync syncs everyone each night, which
 * also catches changes taking effect that day and generates visits as the window moves forward.
 *
 * A No-Cool / No-Heat Call Work Order is Covered when an active entitlement on the account covers the
 * system behind the reported issue, otherwise Not Covered, which RLM_FSL_Bill_Uncovered_Repair bills
 * as HVAC-DIAGNOSTIC when the visit is completed. Entitlements run the Brightline Comfort Response
 * entitlement process, and a Covered call's Priority follows the agreement tier (Premier Critical,
 * Plus High, Basic Medium), which picks its Priority Response milestone: 4, 8 or 24 hours. The
 * milestone is met when its appointment is checked in, started or completed
 * (RLM_HVAC_ServiceAppointmentTrigger).
 */
public with sharing class RLM_HVAC_Coverage {
    public static final String PLAN_TITLE = 'Brightline comfort agreement';
    public static final String INITIAL_TUNEUP = 'Initial Tune-up';
    public static final String SERVICE_CALL = 'No-Cool / No-Heat Call';
    public static final String SPRING_TUNEUP = 'Spring AC Tune-up';
    public static final String FALL_TUNEUP = 'Fall Furnace Tune-up';
    public static final String COVERED = 'Covered';
    public static final String NOT_COVERED = 'Not Covered';
    public static final String GENERATE_FLOW = 'RLM_HVAC_Generate_Maintenance_Visits';
    public static final String RESPONSE_PROCESS = 'Brightline Comfort Response';
    public static final String RESPONSE_MILESTONE = 'Priority Response';
    private static final Set<String> ARRIVED = new Set<String>{ 'CheckedIn', 'InProgress', 'Completed' };

    public class Cadence {
        public final String workType;
        public final String recurrence;
        public final Integer months;
        public final Set<Integer> season;
        public final String systems;
        /** Work order Priority for a covered call; the entitlement process sets the response time from it. */
        public final String priority;
        public final Integer responseHours;

        Cadence(String workType, String recurrence, Integer months, Set<Integer> season, String systems,
                String priority, Integer responseHours) {
            this.workType = workType;
            this.recurrence = recurrence;
            this.months = months;
            this.season = season;
            this.systems = systems;
            this.priority = priority;
            this.responseHours = responseHours;
        }

        public Date firstVisit(Date fromDate) {
            Date visit = fromDate.addMonths(months);
            while (season != null && !season.contains(visit.month())) {
                visit = visit.addMonths(1);
            }
            return visit;
        }

        /** The seasonal tune-up is the AC tune-up in spring and summer and the furnace tune-up the rest of the year. */
        public String workTypeOn(Date visit) {
            if (workType != SPRING_TUNEUP || visit == null) {
                return workType;
            }
            return visit.month() >= 3 && visit.month() <= 8 ? SPRING_TUNEUP : FALL_TUNEUP;
        }
    }

    private static final String HEATING_COOLING = 'Cooling;Heating';
    private static final Set<Integer> TUNEUP_SEASON = new Set<Integer>{ 4, 10 };
    private static final String TUNEUP_RULE = 'FREQ=MONTHLY;BYMONTH=4,10';

    /** Agreement SKUs in the order their work type leads a combined visit. */
    @TestVisible
    private static final Map<String, Cadence> CADENCES = new Map<String, Cadence>{
        'HVAC-PREMIER' => new Cadence(SPRING_TUNEUP, TUNEUP_RULE, 1, TUNEUP_SEASON, HEATING_COOLING, 'Critical', 4),
        'HVAC-PLUS' => new Cadence(SPRING_TUNEUP, TUNEUP_RULE, 1, TUNEUP_SEASON, HEATING_COOLING, 'High', 8),
        'HVAC-BASIC' => new Cadence(SPRING_TUNEUP, TUNEUP_RULE, 1, TUNEUP_SEASON, HEATING_COOLING, 'Medium', 24),
        'HVAC-IAQ' => new Cadence('Indoor Air Quality Visit', 'FREQ=MONTHLY;INTERVAL=3', 3, null,
            'Indoor Air Quality', 'Medium', 24),
        'HVAC-WATER-HEATER' => new Cadence('Water Heater Flush', 'FREQ=YEARLY;INTERVAL=1', 12, null,
            'Water Heater', 'Medium', 24)
    };

    /** The systems a reported issue is about. A call is covered when an entitlement covers any of them. */
    @TestVisible
    private static final Map<String, Set<String>> SYSTEMS_FOR_ISSUE = new Map<String, Set<String>>{
        'No Cool' => new Set<String>{ 'Cooling' },
        'No Heat' => new Set<String>{ 'Heating' },
        'Noise' => new Set<String>{ 'Cooling', 'Heating' },
        'Water Leak' => new Set<String>{ 'Cooling' },
        'Thermostat' => new Set<String>{ 'Cooling', 'Heating' },
        'Air Quality' => new Set<String>{ 'Indoor Air Quality' },
        'Water Heater' => new Set<String>{ 'Water Heater' }
    };

    private static Map<String, Id> workTypeIdsByName;

    @TestVisible
    private static Map<String, Id> workTypeIds() {
        if (workTypeIdsByName == null) {
            Set<String> names = new Set<String>{ INITIAL_TUNEUP, SERVICE_CALL, FALL_TUNEUP };
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

    // ---------- Coverage that follows the plan ----------

    /** Days when a plan asset has a positive quantity. A null end date is open-ended. */
    public class Stretch {
        public final Date startDate;
        public Date endDate;

        public Stretch(Date startDate, Date endDate) {
            this.startDate = startDate;
            this.endDate = endDate;
        }

        public Boolean covers(Date day) {
            return day >= startDate && (endDate == null || day <= endDate);
        }
    }

    /** Asset state periods can't be created in tests, so tests set each asset's stretches here. */
    @TestVisible
    private static Map<Id, List<Stretch>> stretchesByAsset = new Map<Id, List<Stretch>>();

    private class PlanAsset {
        final Asset asset;
        final Cadence cadence;
        final List<Stretch> stretches;

        PlanAsset(Asset asset, List<Stretch> stretches) {
            this.asset = asset;
            this.cadence = CADENCES.get(asset.Product2.StockKeepingUnit);
            this.stretches = stretches;
        }

        Boolean activeOn(Date day) {
            for (Stretch s : stretches) {
                if (s.covers(day)) {
                    return true;
                }
            }
            return false;
        }

        /** The first active day on or after the given day, or null when the plan has ended. */
        Date activeFrom(Date day) {
            for (Stretch s : stretches) {
                if (s.endDate == null || s.endDate >= day) {
                    return s.startDate > day ? s.startDate : day;
                }
            }
            return null;
        }

        /** The first visit on or after the candidate that falls on an active, in-season day. */
        Date visitFrom(Date candidate) {
            Date visit = candidate;
            for (Integer i = 0; i < 60 && activeFrom(visit) != null; i++) {
                if (activeOn(visit) && (cadence.season == null || cadence.season.contains(visit.month()))) {
                    return visit;
                }
                visit = visit.addMonths(cadence.season == null ? cadence.months : 1);
            }
            return null;
        }
    }

    /** Merges the periods with a positive quantity into stretches, joining periods that follow each other. */
    @TestVisible
    private static List<Stretch> stretchesFrom(List<AssetStatePeriod> periods) {
        List<Stretch> stretches = new List<Stretch>();
        for (AssetStatePeriod period : periods) {
            if (period.Quantity == null || period.Quantity <= 0) {
                continue;
            }
            Date startDate = period.StartDate.dateGmt();
            Date endDate = period.EndDate == null ? null : period.EndDate.dateGmt();
            Stretch last = stretches.isEmpty() ? null : stretches[stretches.size() - 1];
            if (last != null && (last.endDate == null || startDate <= last.endDate.addDays(1))) {
                if (last.endDate != null && (endDate == null || endDate > last.endDate)) {
                    last.endDate = endDate;
                }
            } else {
                stretches.add(new Stretch(startDate, endDate));
            }
        }
        return stretches;
    }

    private static Map<Id, List<PlanAsset>> planAssets(Set<Id> accountIds) {
        Map<Id, List<PlanAsset>> byAccount = new Map<Id, List<PlanAsset>>();
        for (Asset a : [
            SELECT Id, Name, AccountId, Product2.StockKeepingUnit, CreatedDate, LifecycleStartDate, LifecycleEndDate,
                HasLifecycleManagement, (SELECT StartDate, EndDate, Quantity FROM AssetStatePeriods ORDER BY StartDate)
            FROM Asset
            WHERE AccountId IN :accountIds AND Product2.StockKeepingUnit IN :CADENCES.keySet()
            ORDER BY CreatedDate
        ]) {
            List<Stretch> stretches = stretchesByAsset.get(a.Id);
            if (stretches == null && !a.AssetStatePeriods.isEmpty()) {
                stretches = stretchesFrom(a.AssetStatePeriods);
            } else if (stretches == null && a.HasLifecycleManagement != true) {
                stretches = new List<Stretch>{ new Stretch(
                    a.LifecycleStartDate != null ? a.LifecycleStartDate.dateGmt() : a.CreatedDate.date(),
                    a.LifecycleEndDate?.dateGmt()) };
            }
            if (!byAccount.containsKey(a.AccountId)) {
                byAccount.put(a.AccountId, new List<PlanAsset>());
            }
            byAccount.get(a.AccountId).add(new PlanAsset(a, stretches == null ? new List<Stretch>() : stretches));
        }
        return byAccount;
    }

    private static Map<Id, MaintenancePlan> plansFor(Set<Id> accountIds) {
        Map<Id, MaintenancePlan> planByAccount = new Map<Id, MaintenancePlan>();
        for (MaintenancePlan mp : [
            SELECT Id, AccountId, WorkTypeId, NextSuggestedMaintenanceDate FROM MaintenancePlan
            WHERE AccountId IN :accountIds AND MaintenancePlanTitle = :PLAN_TITLE
        ]) {
            planByAccount.put(mp.AccountId, mp);
        }
        return planByAccount;
    }

    /** The cadence that leads a combined visit among the plans still running from the given day. */
    private static Cadence leadCadence(List<PlanAsset> assets, Date fromDay) {
        Cadence lead;
        for (PlanAsset pa : assets) {
            if (pa.activeFrom(fromDay) != null && (lead == null || leads(pa.cadence, lead))) {
                lead = pa.cadence;
            }
        }
        return lead;
    }

    private static Boolean leads(Cadence candidate, Cadence current) {
        List<Cadence> order = CADENCES.values();
        return order.indexOf(candidate) < order.indexOf(current);
    }

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
     * Syncs coverage for customers that already have a plan, a few at a time. The nightly run also
     * generates every plan's visits, so the schedule keeps moving forward.
     */
    public class SyncJob implements Queueable {
        private final List<Id> pending;
        private final Boolean generateAll;

        public SyncJob(Set<Id> accountIds, Boolean generateAll) {
            this.pending = new List<Id>(accountIds);
            this.generateAll = generateAll;
        }

        public void execute(QueueableContext context) {
            Set<Id> batch = new Set<Id>();
            while (!pending.isEmpty() && batch.size() < SYNC_BATCH_SIZE) {
                batch.add(pending.remove(0));
            }
            Set<Id> planIds = sync(batch);
            if (generateAll) {
                for (MaintenancePlan mp : plansFor(batch).values()) {
                    planIds.add(mp.Id);
                }
            }
            generate(planIds);
            if (!pending.isEmpty() && !Test.isRunningTest()) {
                System.enqueueJob(new SyncJob(new Set<Id>(pending), generateAll));
            }
        }
    }

    private static final Integer SYNC_BATCH_SIZE = 20;
    /** Lets assetization finish its asset updates before the sync reads the state periods. */
    private static final Integer ASSET_SYNC_DELAY_MINUTES = 1;

    @InvocableMethod(label='Sync Brightline Coverage' category='Field Service'
        description='Brings every Brightline customer\'s agreement entitlements and recurring visits in step with their agreements, and generates upcoming visits.')
    public static void syncAll() {
        Set<Id> accountIds = new Set<Id>();
        for (MaintenancePlan mp : [SELECT AccountId FROM MaintenancePlan WHERE MaintenancePlanTitle = :PLAN_TITLE AND AccountId != null]) {
            accountIds.add(mp.AccountId);
        }
        if (!accountIds.isEmpty()) {
            System.enqueueJob(new SyncJob(accountIds, true));
        }
    }

    /** Agreement assets changed (an amendment, pause, renewal or cancellation was assetized): sync their customers. */
    public static void assetsChanged(List<Asset> assets) {
        Set<Id> productIds = new Set<Id>();
        for (Asset a : assets) {
            if (a.AccountId != null && a.Product2Id != null) {
                productIds.add(a.Product2Id);
            }
        }
        if (productIds.isEmpty()) {
            return;
        }
        Set<Id> planProducts = new Map<Id, Product2>(
            [SELECT Id FROM Product2 WHERE Id IN :productIds AND StockKeepingUnit IN :CADENCES.keySet()]
        ).keySet();
        Set<Id> accountIds = new Set<Id>();
        for (Asset a : assets) {
            if (planProducts.contains(a.Product2Id)) {
                accountIds.add(a.AccountId);
            }
        }
        if (!accountIds.isEmpty() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()
                && !(Test.isRunningTest() && System.isQueueable())) {
            System.enqueueJob(new SyncJob(accountIds, false), Test.isRunningTest() ? 0 : ASSET_SYNC_DELAY_MINUTES);
        }
    }

    /**
     * Starts coverage for the customers' plans: creates the maintenance plan where it is missing,
     * then syncs. Returns the plans whose visit rules changed.
     */
    public static Set<Id> activate(Set<Id> accountIds) {
        Map<Id, List<PlanAsset>> assetsByAccount = planAssets(accountIds);
        Map<Id, MaintenancePlan> planByAccount = plansFor(assetsByAccount.keySet());
        Map<String, Id> workTypes = workTypeIds();
        Date today = Date.today();
        List<MaintenancePlan> newPlans = new List<MaintenancePlan>();
        for (Id accountId : assetsByAccount.keySet()) {
            Cadence lead = leadCadence(assetsByAccount.get(accountId), today);
            if (planByAccount.containsKey(accountId) || lead == null) {
                continue;
            }
            MaintenancePlan mp = new MaintenancePlan(
                AccountId = accountId,
                MaintenancePlanTitle = PLAN_TITLE,
                WorkTypeId = workTypes.get(lead.workType),
                StartDate = today,
                NextSuggestedMaintenanceDate = lead.firstVisit(today),
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
        return sync(assetsByAccount, planByAccount);
    }

    /**
     * Brings coverage in step with the plans for customers that already have a maintenance plan, from
     * their asset state periods: each active stretch of an agreement asset has an entitlement, upcoming visits
     * only include plans active that day, and each running plan has a visit rule. Returns the plans
     * whose visit rules changed, which need generating.
     */
    public static Set<Id> sync(Set<Id> accountIds) {
        Map<Id, List<PlanAsset>> assetsByAccount = planAssets(accountIds);
        return sync(assetsByAccount, plansFor(assetsByAccount.keySet()));
    }

    private static Set<Id> sync(Map<Id, List<PlanAsset>> assetsByAccount, Map<Id, MaintenancePlan> planByAccount) {
        // One assetization fires several asset updates, so syncs for a customer can run at once;
        // locking the account makes them take turns instead of each creating the same records.
        List<Account> locked = [SELECT Id FROM Account WHERE Id IN :planByAccount.keySet() FOR UPDATE];
        List<PlanAsset> covered = new List<PlanAsset>();
        for (Id accountId : planByAccount.keySet()) {
            covered.addAll(assetsByAccount.get(accountId));
        }
        if (covered.isEmpty()) {
            return new Set<Id>();
        }
        syncEntitlements(covered);
        return syncVisits(assetsByAccount, planByAccount);
    }

    private static void syncEntitlements(List<PlanAsset> assets) {
        Set<Id> assetIds = new Set<Id>();
        for (PlanAsset pa : assets) {
            assetIds.add(pa.asset.Id);
        }
        Map<Id, Map<Date, Entitlement>> existing = new Map<Id, Map<Date, Entitlement>>();
        List<Entitlement> unmatched = new List<Entitlement>();
        for (Entitlement e : [
            SELECT Id, AssetId, StartDate, EndDate, SlaProcessId FROM Entitlement
            WHERE AssetId IN :assetIds AND RLM_HVAC_Covered_Systems__c != null
        ]) {
            if (!existing.containsKey(e.AssetId)) {
                existing.put(e.AssetId, new Map<Date, Entitlement>());
            }
            if (existing.get(e.AssetId).containsKey(e.StartDate)) {
                unmatched.add(e);
            } else {
                existing.get(e.AssetId).put(e.StartDate, e);
            }
        }
        Id process = responseProcessId();
        List<Entitlement> changes = new List<Entitlement>();
        for (PlanAsset pa : assets) {
            Map<Date, Entitlement> byStart = existing.containsKey(pa.asset.Id)
                ? existing.get(pa.asset.Id) : new Map<Date, Entitlement>();
            for (Integer i = 0; i < pa.stretches.size(); i++) {
                Stretch s = pa.stretches[i];
                Entitlement e = byStart.remove(s.startDate);
                if (e == null) {
                    changes.add(new Entitlement(
                        Name = (pa.asset.Name + ' coverage' + (i == 0 ? '' : ' from ' + s.startDate.format())).abbreviate(255),
                        AccountId = pa.asset.AccountId,
                        AssetId = pa.asset.Id,
                        StartDate = s.startDate,
                        EndDate = s.endDate,
                        RLM_HVAC_Covered_Systems__c = pa.cadence.systems,
                        SlaProcessId = process
                    ));
                } else if (e.EndDate != s.endDate || (process != null && e.SlaProcessId != process)) {
                    changes.add(new Entitlement(Id = e.Id, EndDate = s.endDate, SlaProcessId = process ?? e.SlaProcessId));
                }
            }
            unmatched.addAll(byStart.values());
        }
        upsert changes;

        // An entitlement that no longer matches the agreement is removed, or ended if a work order used it.
        Set<Id> used = new Set<Id>();
        for (WorkOrder wo : [SELECT EntitlementId FROM WorkOrder WHERE EntitlementId IN :unmatched]) {
            used.add(wo.EntitlementId);
        }
        List<Entitlement> removed = new List<Entitlement>();
        List<Entitlement> ended = new List<Entitlement>();
        Date yesterday = Date.today().addDays(-1);
        for (Entitlement e : unmatched) {
            if (!used.contains(e.Id)) {
                removed.add(e);
            } else if (e.EndDate == null || e.EndDate > yesterday) {
                ended.add(new Entitlement(Id = e.Id, EndDate = e.StartDate > yesterday ? e.StartDate : yesterday));
            }
        }
        delete removed;
        update ended;
    }

    private static Set<Id> syncVisits(Map<Id, List<PlanAsset>> assetsByAccount, Map<Id, MaintenancePlan> planByAccount) {
        Date today = Date.today();
        Map<String, Id> workTypes = workTypeIds();
        Set<Id> planIds = new Map<Id, MaintenancePlan>(planByAccount.values()).keySet();
        Map<Id, PlanAsset> byAssetId = new Map<Id, PlanAsset>();
        for (Id accountId : planByAccount.keySet()) {
            for (PlanAsset pa : assetsByAccount.get(accountId)) {
                byAssetId.put(pa.asset.Id, pa);
            }
        }
        Map<Id, MaintenanceAsset> maintained = new Map<Id, MaintenanceAsset>();
        for (MaintenanceAsset ma : [
            SELECT Id, AssetId, MaintenancePlanId, (SELECT Id, NextSuggestedMaintenanceDate FROM MaintenanceWorkRules)
            FROM MaintenanceAsset WHERE MaintenancePlanId IN :planIds
        ]) {
            maintained.put(ma.AssetId, ma);
        }

        // Upcoming visit lines for a day the plan isn't active move to the new plan that replaced it
        // (an upgrade or downgrade keeps the customer's visit days), or are removed.
        Map<Id, Date> carriedUntil = new Map<Id, Date>();
        List<WorkOrderLineItem> moved = new List<WorkOrderLineItem>();
        List<WorkOrderLineItem> removed = new List<WorkOrderLineItem>();
        Set<Id> emptied = new Set<Id>();
        for (WorkOrderLineItem line : [
            SELECT Id, WorkOrderId, AssetId, SuggestedMaintenanceDate FROM WorkOrderLineItem
            WHERE MaintenancePlanId IN :planIds AND WorkOrder.Status = 'New' AND SuggestedMaintenanceDate >= :today
        ]) {
            PlanAsset pa = byAssetId.get(line.AssetId);
            if (pa == null || pa.activeOn(line.SuggestedMaintenanceDate)) {
                continue;
            }
            PlanAsset replacement = replacementFor(pa, line.SuggestedMaintenanceDate, assetsByAccount.get(pa.asset.AccountId), maintained);
            if (replacement == null) {
                removed.add(line);
                emptied.add(line.WorkOrderId);
                continue;
            }
            moved.add(new WorkOrderLineItem(Id = line.Id, AssetId = replacement.asset.Id));
            Date carried = carriedUntil.get(replacement.asset.Id);
            if (carried == null || line.SuggestedMaintenanceDate > carried) {
                carriedUntil.put(replacement.asset.Id, line.SuggestedMaintenanceDate);
            }
        }
        update moved;
        delete removed;

        // Visit rules: ended plans stop, paused plans resume at their next active visit, new plans start.
        Set<Id> changedPlans = new Set<Id>();
        List<MaintenanceAsset> stopped = new List<MaintenanceAsset>();
        List<MaintenanceAsset> resumedAssets = new List<MaintenanceAsset>();
        List<MaintenanceWorkRule> resumedRules = new List<MaintenanceWorkRule>();
        List<MaintenanceAsset> started = new List<MaintenanceAsset>();
        List<PlanAsset> startedPlans = new List<PlanAsset>();
        List<Date> startedFirstVisits = new List<Date>();
        Map<Id, Date> nextVisitByPlan = new Map<Id, Date>();
        Map<Id, Cadence> leadByPlan = new Map<Id, Cadence>();
        for (PlanAsset pa : byAssetId.values()) {
            Id planId = planByAccount.get(pa.asset.AccountId).Id;
            MaintenanceAsset ma = maintained.get(pa.asset.Id);
            if (ma != null) {
                Date next = ma.MaintenanceWorkRules.isEmpty() ? null : ma.MaintenanceWorkRules[0].NextSuggestedMaintenanceDate;
                Date resume = next == null ? null : pa.visitFrom(next);
                if (resume == null) {
                    stopped.add(ma);
                    continue;
                }
                if (resume != next) {
                    resumedAssets.add(new MaintenanceAsset(Id = ma.Id, NextSuggestedMaintenanceDate = resume));
                    resumedRules.add(new MaintenanceWorkRule(Id = ma.MaintenanceWorkRules[0].Id, NextSuggestedMaintenanceDate = resume));
                    changedPlans.add(planId);
                }
                earliest(nextVisitByPlan, planId, resume);
                lead(leadByPlan, planId, pa.cadence);
                continue;
            }
            Date startDay = pa.activeFrom(today);
            if (startDay == null) {
                continue;
            }
            Date carried = carriedUntil.get(pa.asset.Id);
            Date first = pa.visitFrom(pa.cadence.firstVisit(carried != null ? carried : startDay));
            if (first == null) {
                continue;
            }
            started.add(new MaintenanceAsset(
                MaintenancePlanId = planId,
                AssetId = pa.asset.Id,
                WorkTypeId = workTypes.get(pa.cadence.workType),
                NextSuggestedMaintenanceDate = first
            ));
            startedPlans.add(pa);
            startedFirstVisits.add(first);
            changedPlans.add(planId);
            earliest(nextVisitByPlan, planId, carried != null ? carried : first);
            lead(leadByPlan, planId, pa.cadence);
        }
        delete stopped;
        update resumedAssets;
        update resumedRules;
        insert started;
        List<MaintenanceWorkRule> rules = new List<MaintenanceWorkRule>();
        for (Integer i = 0; i < started.size(); i++) {
            Cadence c = startedPlans[i].cadence;
            rules.add(new MaintenanceWorkRule(
                ParentMaintenanceRecordId = started[i].Id,
                Title = c.workType,
                WorkTypeId = workTypes.get(c.workType),
                Type = 'Calendar',
                SortOrder = 1,
                RecurrencePattern = c.recurrence,
                NextSuggestedMaintenanceDate = startedFirstVisits[i]
            ));
        }
        insert rules;

        syncUpcomingVisits(planIds, byAssetId, emptied);

        // The plan leads with the plan of its own that still has visits, and points at its next visit.
        List<MaintenancePlan> planUpdates = new List<MaintenancePlan>();
        for (MaintenancePlan mp : planByAccount.values()) {
            Cadence lead = leadByPlan.get(mp.Id);
            Id workTypeId = lead == null ? mp.WorkTypeId : workTypes.get(lead.workType);
            Date next = nextVisitByPlan.get(mp.Id);
            if (workTypeId != mp.WorkTypeId || (next != null && next != mp.NextSuggestedMaintenanceDate)) {
                planUpdates.add(new MaintenancePlan(Id = mp.Id, WorkTypeId = workTypeId,
                    NextSuggestedMaintenanceDate = next != null ? next : mp.NextSuggestedMaintenanceDate));
            }
        }
        update planUpdates;
        return changedPlans;
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

    /** A plan with the same visit type that is active on the day and has no visit rule yet. */
    private static PlanAsset replacementFor(PlanAsset ended, Date day, List<PlanAsset> accountAssets, Map<Id, MaintenanceAsset> maintained) {
        for (PlanAsset pa : accountAssets) {
            if (pa !== ended && pa.cadence.workType == ended.cadence.workType && pa.activeOn(day)
                    && !maintained.containsKey(pa.asset.Id)) {
                return pa;
            }
        }
        return null;
    }

    private static void lead(Map<Id, Cadence> byPlan, Id planId, Cadence candidate) {
        if (!byPlan.containsKey(planId) || leads(candidate, byPlan.get(planId))) {
            byPlan.put(planId, candidate);
        }
    }

    private static void earliest(Map<Id, Date> byPlan, Id planId, Date day) {
        if (day != null && (!byPlan.containsKey(planId) || day < byPlan.get(planId))) {
            byPlan.put(planId, day);
        }
    }

    /** Visits that lost all their lines are removed with their appointment; the rest take their leading plan's work type. */
    private static void syncUpcomingVisits(Set<Id> planIds, Map<Id, PlanAsset> byAssetId, Set<Id> emptied) {
        Map<String, Id> workTypes = workTypeIds();
        List<WorkOrder> empty = new List<WorkOrder>();
        List<WorkOrder> retyped = new List<WorkOrder>();
        for (WorkOrder wo : [
            SELECT Id, WorkTypeId, SuggestedMaintenanceDate, (SELECT AssetId FROM WorkOrderLineItems)
            FROM WorkOrder
            WHERE MaintenancePlanId IN :planIds AND Status = 'New' AND SuggestedMaintenanceDate >= :Date.today()
        ]) {
            if (wo.WorkOrderLineItems.isEmpty()) {
                if (emptied.contains(wo.Id)) {
                    empty.add(wo);
                }
                continue;
            }
            Cadence lead;
            for (WorkOrderLineItem line : wo.WorkOrderLineItems) {
                PlanAsset pa = byAssetId.get(line.AssetId);
                if (pa != null && (lead == null || leads(pa.cadence, lead))) {
                    lead = pa.cadence;
                }
            }
            Id workTypeId = lead == null ? null : workTypes.get(lead.workTypeOn(wo.SuggestedMaintenanceDate));
            if (workTypeId != null && workTypeId != wo.WorkTypeId) {
                retyped.add(new WorkOrder(Id = wo.Id, WorkTypeId = workTypeId));
            }
        }
        delete empty;
        update retyped;
    }

    // ---------- Work Order trigger ----------

    public static void beforeSave(List<WorkOrder> records, Map<Id, WorkOrder> oldMap) {
        Map<String, Id> workTypes = workTypeIds();
        Id serviceCall = workTypes.get(SERVICE_CALL);
        List<WorkOrder> visits = new List<WorkOrder>();
        List<WorkOrder> serviceCalls = new List<WorkOrder>();
        for (WorkOrder wo : records) {
            if (wo.AccountId == null) {
                continue;
            }
            Boolean isServiceCall = serviceCall != null && wo.WorkTypeId == serviceCall;
            if (oldMap == null && (wo.MaintenancePlanId != null || isServiceCall)) {
                visits.add(wo);
            }
            if (isServiceCall && needsCoverageCheck(wo, oldMap == null ? null : oldMap.get(wo.Id))) {
                serviceCalls.add(wo);
            }
        }
        if (!visits.isEmpty()) {
            fillVisitDefaults(visits);
        }
        if (!serviceCalls.isEmpty()) {
            checkCoverage(serviceCalls);
        }
    }

    public static void afterUpdate(List<WorkOrder> records, Map<Id, WorkOrder> oldMap) {
        Id initial = workTypeIds().get(INITIAL_TUNEUP);
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
        return wo.RLM_HVAC_Reported_Issue__c != old.RLM_HVAC_Reported_Issue__c || wo.AccountId != old.AccountId
            || wo.WorkTypeId != old.WorkTypeId || wo.RLM_Service_Coverage__c == null;
    }

    /** Copies territory, address and contact from the customer's latest visit, links their accepted system check, and sets the seasonal tune-up's work type from its month. */
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
        Map<Id, Id> assessmentByAccount = new Map<Id, Id>();
        for (RLM_HVAC_Assessment__c assessment : [
            SELECT Id, Account__c FROM RLM_HVAC_Assessment__c
            WHERE Account__c IN :accountIds AND Status__c = 'Accepted'
            ORDER BY CreatedDate DESC
            LIMIT 500
        ]) {
            if (!assessmentByAccount.containsKey(assessment.Account__c)) {
                assessmentByAccount.put(assessment.Account__c, assessment.Id);
            }
        }
        Map<String, Id> workTypes = workTypeIds();
        Id spring = workTypes.get(SPRING_TUNEUP);
        Id fall = workTypes.get(FALL_TUNEUP);
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
            if (wo.RLM_HVAC_Assessment__c == null) {
                wo.RLM_HVAC_Assessment__c = assessmentByAccount.get(wo.AccountId);
            }
            MaintenancePlan plan = plans.get(wo.MaintenancePlanId);
            if (plan != null && wo.WorkTypeId == null) {
                wo.WorkTypeId = plan.WorkTypeId;
            }
            Date visit = wo.SuggestedMaintenanceDate;
            if (spring != null && fall != null && wo.WorkTypeId == spring && visit != null
                    && (visit.month() < 3 || visit.month() > 8)) {
                wo.WorkTypeId = fall;
            }
        }
    }

    /** Covered when an active entitlement on the account covers the system behind the reported issue; Priority follows its tier. */
    @TestVisible
    private static void checkCoverage(List<WorkOrder> serviceCalls) {
        Set<Id> accountIds = new Set<Id>();
        for (WorkOrder wo : serviceCalls) {
            accountIds.add(wo.AccountId);
        }
        Date today = Date.today();
        List<Entitlement> entitlements = [
            SELECT Id, AccountId, AssetId, Asset.Product2.StockKeepingUnit, RLM_HVAC_Covered_Systems__c
            FROM Entitlement
            WHERE AccountId IN :accountIds AND RLM_HVAC_Covered_Systems__c != null
                AND StartDate <= :today AND (EndDate = null OR EndDate >= :today)
            ORDER BY StartDate DESC
        ];
        for (WorkOrder wo : serviceCalls) {
            if (String.isBlank(wo.RLM_HVAC_Reported_Issue__c)) {
                wo.RLM_Service_Coverage__c = null;
                wo.EntitlementId = null;
                continue;
            }
            Entitlement match = coveringEntitlement(entitlements, wo.AccountId, wo.RLM_HVAC_Reported_Issue__c);
            wo.RLM_Service_Coverage__c = match != null ? COVERED : NOT_COVERED;
            wo.EntitlementId = match?.Id;
            if (match != null && wo.AssetId == null) {
                wo.AssetId = match.AssetId;
            }
            Cadence tier = match == null ? null : CADENCES.get(match.Asset?.Product2?.StockKeepingUnit);
            if (tier != null) {
                wo.Priority = tier.priority;
            }
        }
    }

    /** The account's best entitlement for the issue: the agreement with the fastest response that covers it. */
    private static Entitlement coveringEntitlement(List<Entitlement> entitlements, Id accountId, String issue) {
        Set<String> systems = SYSTEMS_FOR_ISSUE.get(issue);
        if (systems == null) {
            return null;
        }
        Entitlement best;
        Integer bestHours;
        for (Entitlement e : entitlements) {
            if (e.AccountId != accountId) {
                continue;
            }
            Set<String> covered = new Set<String>(e.RLM_HVAC_Covered_Systems__c.split(';'));
            covered.retainAll(systems);
            if (covered.isEmpty()) {
                continue;
            }
            Cadence c = CADENCES.get(e.Asset?.Product2?.StockKeepingUnit);
            Integer hours = c == null ? 24 : c.responseHours;
            if (best == null || hours < bestHours) {
                best = e;
                bestHours = hours;
            }
        }
        return best;
    }

    /** Response hours for a covered call under the agreement, for the response countdown. */
    /** Covered systems that can handle a reported issue, such as Cooling for No Cool; empty for an unknown issue. */
    public static Set<String> systemsForIssue(String issue) {
        Set<String> systems = SYSTEMS_FOR_ISSUE.get(issue);
        return systems == null ? new Set<String>() : systems.clone();
    }

    public static Integer responseHoursFor(String sku) {
        Cadence c = CADENCES.get(sku);
        return c == null ? null : c.responseHours;
    }

    // ---------- Priority response ----------

    private static Id responseProcessId() {
        List<SlaProcess> processes = [
            SELECT Id FROM SlaProcess
            WHERE Name = :RESPONSE_PROCESS AND IsActive = true
            LIMIT 1
        ];
        return processes.isEmpty() ? null : processes[0].Id;
    }

    /** A covered call's response milestone is met when its technician arrives. */
    public static void appointmentsChanged(List<ServiceAppointment> records, Map<Id, ServiceAppointment> oldMap) {
        Datetime now = Datetime.now();
        Map<Id, Datetime> arrivalByWorkOrder = new Map<Id, Datetime>();
        for (ServiceAppointment sa : records) {
            ServiceAppointment old = oldMap.get(sa.Id);
            if (sa.ParentRecordId != null && sa.ParentRecordId.getSobjectType() == WorkOrder.SObjectType
                    && ARRIVED.contains(sa.StatusCategory) && !ARRIVED.contains(old.StatusCategory)) {
                Datetime arrival = sa.ActualStartTime ?? now;
                Datetime earliest = arrivalByWorkOrder.get(sa.ParentRecordId);
                if (earliest == null || arrival < earliest) {
                    arrivalByWorkOrder.put(sa.ParentRecordId, arrival);
                }
            }
        }
        if (arrivalByWorkOrder.isEmpty()) {
            return;
        }
        List<EntityMilestone> met = new List<EntityMilestone>();
        for (EntityMilestone m : [
            SELECT Id, ParentEntityId, StartDate FROM EntityMilestone
            WHERE ParentEntityId IN :arrivalByWorkOrder.keySet() AND MilestoneType.Name = :RESPONSE_MILESTONE
                AND IsCompleted = false
        ]) {
            Datetime arrival = arrivalByWorkOrder.get(m.ParentEntityId);
            if (arrival > now) {
                arrival = now;
            }
            if (m.StartDate != null && arrival < m.StartDate) {
                arrival = m.StartDate;
            }
            met.add(new EntityMilestone(Id = m.Id, CompletionDate = arrival));
        }
        update met;
    }
}

/**
 * System check for Brightline residential HVAC. Stores findings (with photos as Files on each
 * finding, data-plate details and readings) and turns them into a recommended comfort agreement,
 * add-ons, repairs, a replacement flag and the equipment age band for RLM_HVAC_FieldQuote.
 */
public with sharing class RLM_HVAC_Assessment {
    public static final String BASIC = 'HVAC-BASIC';
    public static final String PLUS = 'HVAC-PLUS';
    public static final String PREMIER = 'HVAC-PREMIER';
    public static final String IAQ = 'HVAC-IAQ';
    public static final String WATER_HEATER = 'HVAC-WATER-HEATER';
    public static final String COIL_CLEAN = 'HVAC-COIL-CLEAN';
    public static final String CAPACITOR = 'HVAC-CAPACITOR';
    public static final String CONTACTOR = 'HVAC-CONTACTOR';
    public static final String DRAIN_CLEAR = 'HVAC-DRAIN-CLEAR';
    public static final String REFRIGERANT = 'HVAC-REFRIGERANT';
    public static final String BLOWER_MOTOR = 'HVAC-BLOWER-MOTOR';
    /** Equipment this old or older gets a replacement recommendation. */
    public static final Integer REPLACEMENT_AGE = 12;

    public static final Map<String, String> PRODUCT_NAMES = new Map<String, String>{
        BASIC => 'Comfort Basic',
        PLUS => 'Comfort Plus',
        PREMIER => 'Comfort Premier',
        IAQ => 'Indoor Air Quality',
        WATER_HEATER => 'Water Heater Care',
        COIL_CLEAN => 'Coil Cleaning',
        CAPACITOR => 'Capacitor Replacement',
        CONTACTOR => 'Contactor Replacement',
        DRAIN_CLEAR => 'Condensate Drain Clear',
        REFRIGERANT => 'Refrigerant Leak Check and Recharge',
        BLOWER_MOTOR => 'Blower Motor Replacement'
    };
    private static final List<String> REPAIR_SKUS = new List<String>{
        COIL_CLEAN, CAPACITOR, CONTACTOR, DRAIN_CLEAR, REFRIGERANT, BLOWER_MOTOR
    };
    private static final Map<String, Integer> URGENCY_RANK = new Map<String, Integer>{
        'Monitor' => 1, 'Repair Soon' => 2, 'Safety' => 3
    };
    private static final Set<String> MAIN_EQUIPMENT = new Set<String>{
        'Outdoor Unit', 'Furnace', 'Air Handler', 'Heat Pump', 'Boiler'
    };

    public class PhotoView {
        @AuraEnabled public Id versionId;
        @AuraEnabled public Id documentId;
        @AuraEnabled public String title;
        @AuraEnabled public String stage;
        @AuraEnabled public String url;
    }

    public class FindingView {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String equipment;
        @AuraEnabled public String component;
        @AuraEnabled public String condition;
        @AuraEnabled public String urgency;
        @AuraEnabled public String make;
        @AuraEnabled public String modelNumber;
        @AuraEnabled public String serialNumber;
        @AuraEnabled public Integer installYear;
        @AuraEnabled public String reading;
        @AuraEnabled public String customerNote;
        @AuraEnabled public String internalNote;
        @AuraEnabled public String recommendedProduct;
        @AuraEnabled public String recommendedProductName;
        @AuraEnabled public List<PhotoView> photos = new List<PhotoView>();
        @AuraEnabled public List<PhotoView> afterPhotos = new List<PhotoView>();
        @AuraEnabled public String workStatus;
        @AuraEnabled public String workNote;
        @AuraEnabled public Datetime completedOn;
    }

    public class Reason {
        @AuraEnabled public String sku;
        @AuraEnabled public String productName;
        @AuraEnabled public List<String> because = new List<String>();
    }

    public class Recommendation {
        @AuraEnabled public String planSku;
        @AuraEnabled public String urgency;
        @AuraEnabled public String systemType;
        @AuraEnabled public Integer systemCount = 1;
        /** Age band of the oldest main equipment (0to5, 6to10, 11to15, Over15). */
        @AuraEnabled public String equipmentAge;
        @AuraEnabled public Integer oldestAge;
        @AuraEnabled public Boolean includeIaq = false;
        @AuraEnabled public Boolean includeWaterHeater = false;
        @AuraEnabled public Boolean replacementRecommended = false;
        @AuraEnabled public Boolean safetyFlag = false;
        @AuraEnabled public List<String> repairSkus = new List<String>();
        @AuraEnabled public List<Reason> reasons = new List<Reason>();
        @AuraEnabled public String summary;
    }

    /** One step of the tune-up for the home's system type, with the reading the technician took. */
    public class ServiceStep {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        /** What to measure, such as "µF" or "psi"; null for a step with no reading. */
        @AuraEnabled public String readingHint;
        @AuraEnabled public Boolean done = false;
        @AuraEnabled public String reading;

        ServiceStep(String key, String label, String readingHint) {
            this.key = key;
            this.label = label;
            this.readingHint = readingHint;
        }
    }

    public class AssessmentState {
        @AuraEnabled public Id assessmentId;
        @AuraEnabled public String assessmentName;
        @AuraEnabled public Id workOrderId;
        @AuraEnabled public Integer doneCount = 0;
        @AuraEnabled public String systemType;
        @AuraEnabled public String workTypeName;
        @AuraEnabled public List<ServiceStep> steps = new List<ServiceStep>();
        @AuraEnabled public Integer stepsDone = 0;
        @AuraEnabled public List<FindingView> findings = new List<FindingView>();
        @AuraEnabled public Recommendation recommendation;
        /** Plain-language "why this agreement" from RLM_HVAC_AI.explainPlan, when written. */
        @AuraEnabled public String planExplanation;
        /** How the quoted agreement price is built, when it includes an equipment age adjustment. */
        @AuraEnabled public String priceNote;
    }

    public class FindingInput {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String equipment { get; set; }
        @AuraEnabled public String component { get; set; }
        @AuraEnabled public String condition { get; set; }
        @AuraEnabled public String urgency { get; set; }
        @AuraEnabled public String make { get; set; }
        @AuraEnabled public String modelNumber { get; set; }
        @AuraEnabled public String serialNumber { get; set; }
        @AuraEnabled public Integer installYear { get; set; }
        @AuraEnabled public String reading { get; set; }
        @AuraEnabled public String customerNote { get; set; }
        @AuraEnabled public String internalNote { get; set; }
    }

    @AuraEnabled
    public static AssessmentState getState(Id assessmentId) {
        return refresh(assessmentId);
    }

    /** Sets the home's main system type and how many systems it has; both feed the recommendation. */
    @AuraEnabled
    public static AssessmentState saveSystems(Id assessmentId, String systemType, Integer systemCount) {
        try {
            update new RLM_HVAC_Assessment__c(
                Id = assessmentId,
                System_Type__c = String.isBlank(systemType) ? 'AcFurnace' : systemType,
                System_Count__c = systemCount == null || systemCount < 1 ? 1 : systemCount
            );
            return refresh(assessmentId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Customer-facing view of the system check behind a quote (no internal notes). Null when the quote has none. */
    @AuraEnabled(cacheable=true)
    public static AssessmentState getQuoteFindings(Id quoteId) {
        if (quoteId == null) {
            return null;
        }
        List<RLM_HVAC_Assessment__c> assessments = [
            SELECT Id, Name, Plan_Explanation__c, Equipment_Age__c, System_Type__c, System_Count__c, Age_Adjustment__c
            FROM RLM_HVAC_Assessment__c
            WHERE Quote__c = :quoteId ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (assessments.isEmpty()) {
            return null;
        }
        RLM_HVAC_Assessment__c assessment = assessments[0];
        List<RLM_HVAC_Finding__c> findings = queryFindings(assessment.Id);
        AssessmentState state = buildState(assessment.Id, findings, recommend(findings, assessment));
        state.assessmentName = assessment.Name;
        state.planExplanation = assessment.Plan_Explanation__c;
        Set<String> quotedSkus = new Set<String>();
        for (QuoteLineItem line : [
            SELECT Product2.StockKeepingUnit, Product2.Name, UnitPrice FROM QuoteLineItem WHERE QuoteId = :quoteId
        ]) {
            String sku = line.Product2.StockKeepingUnit;
            quotedSkus.add(sku);
            if (sku == BASIC || sku == PLUS || sku == PREMIER) {
                state.priceNote = priceNote(line.Product2.Name, line.UnitPrice, assessment);
            }
        }
        for (FindingView v : state.findings) {
            v.internalNote = null;
            v.afterPhotos = new List<PhotoView>();
            if (!quotedSkus.contains(v.recommendedProduct)) {
                v.recommendedProductName = null;
            }
        }
        return state;
    }

    @TestVisible
    private static String priceNote(String planName, Decimal unitPrice, RLM_HVAC_Assessment__c assessment) {
        Decimal adjustment = assessment.Age_Adjustment__c;
        if (adjustment == null || adjustment <= 0) {
            return null;
        }
        return 'Your ' + planName + ' price of ' + RLM_HVAC_FieldQuote.money(unitPrice)
            + '/mo per system includes a ' + RLM_HVAC_FieldQuote.money(adjustment) + '/mo equipment age adjustment ('
            + RLM_HVAC_FieldQuote.adjustmentReasons(assessment.Equipment_Age__c)
            + '). It comes off when the equipment is replaced.';
    }

    /**
     * Technician view of a work order: the tune-up steps for the home's system type and the season,
     * and the findings from the system check it services, with internal notes and after photos.
     * Null when there is no work order.
     */
    @AuraEnabled
    public static AssessmentState getWorkOrderFindings(Id workOrderId) {
        if (workOrderId == null) {
            return null;
        }
        List<WorkOrder> orders = [
            SELECT WorkType.Name, RLM_HVAC_Service_Steps__c FROM WorkOrder WHERE Id = :workOrderId
        ];
        if (orders.isEmpty()) {
            return null;
        }
        Id assessmentId = assessmentFor(workOrderId);
        AssessmentState state;
        if (assessmentId == null) {
            state = new AssessmentState();
            state.systemType = 'AcFurnace';
        } else {
            RLM_HVAC_Assessment__c assessment = queryAssessment(assessmentId);
            List<RLM_HVAC_Finding__c> findings = queryFindings(assessmentId);
            state = buildState(assessmentId, findings, recommend(findings, assessment));
            state.assessmentName = assessment.Name;
            state.systemType = String.isBlank(assessment.System_Type__c) ? 'AcFurnace' : assessment.System_Type__c;
            for (FindingView v : state.findings) {
                if (v.workStatus == 'Done') {
                    state.doneCount++;
                }
            }
        }
        state.workOrderId = workOrderId;
        state.workTypeName = orders[0].WorkType?.Name;
        state.steps = stepsFor(state.systemType, state.workTypeName, orders[0].RLM_HVAC_Service_Steps__c);
        for (ServiceStep step : state.steps) {
            if (step.done) {
                state.stepsDone++;
            }
        }
        return state;
    }

    /** Marks a tune-up step done or not and keeps its reading on the work order. */
    @AuraEnabled
    public static AssessmentState saveStep(Id workOrderId, String stepKey, Boolean done, String reading) {
        try {
            WorkOrder wo = [SELECT Id, RLM_HVAC_Service_Steps__c FROM WorkOrder WHERE Id = :workOrderId];
            Map<String, Object> saved = savedSteps(wo.RLM_HVAC_Service_Steps__c);
            saved.put(stepKey, new Map<String, Object>{
                'done' => done == true,
                'reading' => String.isBlank(reading) ? null : reading.trim().abbreviate(120)
            });
            update new WorkOrder(Id = wo.Id, RLM_HVAC_Service_Steps__c = JSON.serialize(saved));
            return getWorkOrderFindings(workOrderId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Tune-up steps done on a work order, with readings, for the customer summary. */
    public static List<String> completedSteps(Id workOrderId) {
        List<String> lines = new List<String>();
        AssessmentState state = getWorkOrderFindings(workOrderId);
        if (state == null) {
            return lines;
        }
        for (ServiceStep step : state.steps) {
            if (step.done) {
                lines.add(step.label + (String.isBlank(step.reading) ? '' : ' (' + step.reading + ')'));
            }
        }
        return lines;
    }

    private static final String COOL = 'cool';
    private static final String HEAT = 'heat';
    private static final String BOTH = 'both';

    /** Tune-up steps by system type: key, label, reading hint (blank for none) and season. */
    private static final Map<String, List<List<String>>> STEPS = new Map<String, List<List<String>>>{
        'AcFurnace' => new List<List<String>>{
            new List<String>{ 'filter', 'Replace the air filter', '', BOTH },
            new List<String>{ 'thermostat', 'Check thermostat calibration and cycling', '°F', BOTH },
            new List<String>{ 'condenser', 'Clean the condenser coil and clear the unit', '', COOL },
            new List<String>{ 'capacitor', 'Test the run capacitor', 'µF', COOL },
            new List<String>{ 'contactor', 'Inspect the contactor', '', COOL },
            new List<String>{ 'refrigerant', 'Check the refrigerant charge', 'psi / superheat', COOL },
            new List<String>{ 'drain', 'Flush the condensate drain', '', COOL },
            new List<String>{ 'split', 'Measure the supply and return temperature split', '°F', COOL },
            new List<String>{ 'burners', 'Clean the burners and flame sensor', '', HEAT },
            new List<String>{ 'igniter', 'Test the igniter', 'ohms', HEAT },
            new List<String>{ 'exchanger', 'Inspect the heat exchanger', '', HEAT },
            new List<String>{ 'co', 'Test for carbon monoxide', 'ppm', HEAT },
            new List<String>{ 'blower', 'Inspect the blower motor and wheel', 'amps', BOTH }
        },
        'HeatPump' => new List<List<String>>{
            new List<String>{ 'filter', 'Replace the air filter', '', BOTH },
            new List<String>{ 'thermostat', 'Check thermostat calibration and cycling', '°F', BOTH },
            new List<String>{ 'coils', 'Clean the outdoor and indoor coils', '', BOTH },
            new List<String>{ 'capacitor', 'Test the run capacitor', 'µF', BOTH },
            new List<String>{ 'contactor', 'Inspect the contactor', '', BOTH },
            new List<String>{ 'refrigerant', 'Check the refrigerant charge', 'psi / superheat', BOTH },
            new List<String>{ 'reversing', 'Test the reversing valve in both modes', '', BOTH },
            new List<String>{ 'defrost', 'Test the defrost cycle', '', HEAT },
            new List<String>{ 'strips', 'Check the backup heat strips', 'amps', HEAT },
            new List<String>{ 'drain', 'Flush the condensate drain', '', COOL },
            new List<String>{ 'split', 'Measure the supply and return temperature split', '°F', BOTH }
        },
        'Boiler' => new List<List<String>>{
            new List<String>{ 'pressure', 'Check system pressure', 'psi', BOTH },
            new List<String>{ 'relief', 'Test the pressure relief valve', '', BOTH },
            new List<String>{ 'expansion', 'Check the expansion tank', 'psi', BOTH },
            new List<String>{ 'burner', 'Clean the burner and check the flame', '', BOTH },
            new List<String>{ 'flue', 'Inspect the flue and venting', '', BOTH },
            new List<String>{ 'co', 'Test for carbon monoxide', 'ppm', BOTH },
            new List<String>{ 'circulator', 'Check the circulator pump', 'amps', BOTH },
            new List<String>{ 'lwco', 'Test the low-water cutoff', '', BOTH },
            new List<String>{ 'bleed', 'Bleed air from the radiators', '', BOTH },
            new List<String>{ 'thermostat', 'Check thermostat calibration and cycling', '°F', BOTH }
        }
    };

    /** The steps for the system type, only cooling ones in a spring tune-up and heating ones in a fall tune-up. */
    @TestVisible
    private static List<ServiceStep> stepsFor(String systemType, String workTypeName, String savedJson) {
        List<List<String>> definitions = STEPS.containsKey(systemType) ? STEPS.get(systemType) : STEPS.get('AcFurnace');
        String season = workTypeName == null ? null
            : workTypeName.containsIgnoreCase('spring') ? COOL
            : workTypeName.containsIgnoreCase('fall') ? HEAT : null;
        Map<String, Object> saved = savedSteps(savedJson);
        List<ServiceStep> steps = new List<ServiceStep>();
        for (List<String> d : definitions) {
            if (season != null && d[3] != BOTH && d[3] != season) {
                continue;
            }
            ServiceStep step = new ServiceStep(d[0], d[1], String.isBlank(d[2]) ? null : d[2]);
            Object value = saved.get(step.key);
            if (value instanceof Map<String, Object>) {
                Map<String, Object> m = (Map<String, Object>) value;
                step.done = m.get('done') == true;
                step.reading = m.get('reading') == null ? null : String.valueOf(m.get('reading'));
            }
            steps.add(step);
        }
        return steps;
    }

    private static Map<String, Object> savedSteps(String savedJson) {
        if (String.isBlank(savedJson)) {
            return new Map<String, Object>();
        }
        try {
            Object parsed = JSON.deserializeUntyped(savedJson);
            return parsed instanceof Map<String, Object> ? (Map<String, Object>) parsed : new Map<String, Object>();
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }

    @AuraEnabled
    public static AssessmentState saveWork(Id workOrderId, Id findingId, String status, String note, String reading) {
        try {
            requireFindingOnWorkOrder(workOrderId, findingId);
            RLM_HVAC_Finding__c record = new RLM_HVAC_Finding__c(
                Id = findingId,
                Work_Status__c = String.isBlank(status) ? 'Open' : status,
                Work_Note__c = note,
                Completed_On__c = Datetime.now()
            );
            if (String.isNotBlank(reading)) {
                record.Reading__c = reading;
            }
            update record;
            return getWorkOrderFindings(workOrderId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Marks files just uploaded to a finding from the work order as After photos. */
    @AuraEnabled
    public static AssessmentState tagAfterPhotos(Id workOrderId, Id findingId, List<Id> documentIds) {
        try {
            requireFindingOnWorkOrder(workOrderId, findingId);
            Set<Id> onFinding = new Set<Id>();
            for (ContentDocumentLink link : [
                SELECT ContentDocumentId FROM ContentDocumentLink
                WHERE LinkedEntityId = :findingId AND ContentDocumentId IN :documentIds
            ]) {
                onFinding.add(link.ContentDocumentId);
            }
            List<ContentVersion> versions = [
                SELECT Id FROM ContentVersion WHERE ContentDocumentId IN :onFinding AND IsLatest = true
            ];
            for (ContentVersion v : versions) {
                v.RLM_HVAC_Photo_Stage__c = 'After';
            }
            update versions;
            return getWorkOrderFindings(workOrderId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /**
     * Saves a photo on a finding from base64 image data. Used instead of lightning-file-upload,
     * which the Field Service mobile app does not support.
     */
    @AuraEnabled
    public static Id uploadPhoto(Id findingId, String fileName, String base64Data, String stage) {
        try {
            if ([SELECT COUNT() FROM RLM_HVAC_Finding__c WHERE Id = :findingId] == 0) {
                throw new AssessmentException('That finding no longer exists.');
            }
            if (String.isBlank(base64Data)) {
                throw new AssessmentException('The photo was empty.');
            }
            String name = String.isBlank(fileName) ? 'photo.jpg' : fileName;
            ContentVersion version = new ContentVersion(
                Title = name.substringBeforeLast('.'),
                PathOnClient = name,
                VersionData = EncodingUtil.base64Decode(base64Data),
                FirstPublishLocationId = findingId,
                RLM_HVAC_Photo_Stage__c = stage == 'After' ? 'After' : 'Before'
            );
            insert version;
            return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id].ContentDocumentId;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    private static Id assessmentFor(Id workOrderId) {
        if (workOrderId == null) {
            return null;
        }
        List<WorkOrder> orders = [
            SELECT RLM_HVAC_Assessment__c, RLM_Order__r.QuoteId FROM WorkOrder WHERE Id = :workOrderId
        ];
        if (orders.isEmpty()) {
            return null;
        }
        if (orders[0].RLM_HVAC_Assessment__c != null) {
            return orders[0].RLM_HVAC_Assessment__c;
        }
        Id quoteId = orders[0].RLM_Order__r?.QuoteId;
        if (quoteId == null) {
            return null;
        }
        List<RLM_HVAC_Assessment__c> assessments = [
            SELECT Id FROM RLM_HVAC_Assessment__c WHERE Quote__c = :quoteId ORDER BY CreatedDate DESC LIMIT 1
        ];
        return assessments.isEmpty() ? null : assessments[0].Id;
    }

    private static void requireFindingOnWorkOrder(Id workOrderId, Id findingId) {
        Id assessmentId = assessmentFor(workOrderId);
        if (assessmentId == null
            || [SELECT COUNT() FROM RLM_HVAC_Finding__c WHERE Id = :findingId AND Assessment__c = :assessmentId] == 0) {
            throw new AssessmentException('That finding is not part of this work order\'s system check.');
        }
    }

    private class AssessmentException extends Exception {}

    private static AuraHandledException auraError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }

    @AuraEnabled
    public static AssessmentState saveFinding(Id assessmentId, FindingInput finding) {
        try {
            RLM_HVAC_Finding__c record = new RLM_HVAC_Finding__c(
                Equipment__c = finding.equipment,
                Component__c = finding.component,
                Condition__c = finding.condition,
                Urgency__c = String.isBlank(finding.urgency) ? 'Monitor' : finding.urgency,
                Make__c = finding.make,
                Model_Number__c = finding.modelNumber,
                Serial_Number__c = finding.serialNumber,
                Install_Year__c = finding.installYear,
                Reading__c = finding.reading,
                Customer_Note__c = finding.customerNote,
                Internal_Note__c = finding.internalNote
            );
            if (finding.id != null) {
                record.Id = finding.id;
                update record;
            } else {
                record.Assessment__c = assessmentId;
                insert record;
            }
            return refresh(assessmentId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static AssessmentState deleteFinding(Id assessmentId, Id findingId) {
        try {
            List<ContentDocumentLink> links = [
                SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :findingId
            ];
            Set<Id> docIds = new Set<Id>();
            for (ContentDocumentLink link : links) {
                docIds.add(link.ContentDocumentId);
            }
            delete new RLM_HVAC_Finding__c(Id = findingId);
            if (!docIds.isEmpty()) {
                delete [SELECT Id FROM ContentDocument WHERE Id IN :docIds];
            }
            return refresh(assessmentId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Recomputes the recommendation, stamps it on the system check and findings, and returns the full state. */
    public static AssessmentState refresh(Id assessmentId) {
        RLM_HVAC_Assessment__c assessment = queryAssessment(assessmentId);
        List<RLM_HVAC_Finding__c> findings = queryFindings(assessmentId);
        Recommendation rec = recommend(findings, assessment);

        List<RLM_HVAC_Finding__c> changed = new List<RLM_HVAC_Finding__c>();
        for (RLM_HVAC_Finding__c f : findings) {
            String sku = productFor(f, rec.planSku);
            if (f.Recommended_Product__c != sku) {
                f.Recommended_Product__c = sku;
                changed.add(f);
            }
        }
        update changed;
        update new RLM_HVAC_Assessment__c(
            Id = assessmentId,
            Overall_Urgency__c = rec.urgency,
            Recommended_Plan__c = rec.planSku,
            Recommended_IAQ__c = rec.includeIaq,
            Recommended_Water_Heater__c = rec.includeWaterHeater,
            Replacement_Recommended__c = rec.replacementRecommended,
            Recommendation_Summary__c = rec.summary
        );
        AssessmentState state = buildState(assessmentId, findings, rec);
        state.assessmentName = assessment.Name;
        return state;
    }

    private static RLM_HVAC_Assessment__c queryAssessment(Id assessmentId) {
        return [
            SELECT Id, Name, System_Type__c, System_Count__c, Equipment_Age__c
            FROM RLM_HVAC_Assessment__c WHERE Id = :assessmentId
        ];
    }

    private static List<RLM_HVAC_Finding__c> queryFindings(Id assessmentId) {
        return [
            SELECT Id, Name, Equipment__c, Component__c, Condition__c, Urgency__c, Make__c, Model_Number__c,
                Serial_Number__c, Install_Year__c, Reading__c, Customer_Note__c, Internal_Note__c,
                Recommended_Product__c, Work_Status__c, Work_Note__c, Completed_On__c
            FROM RLM_HVAC_Finding__c
            WHERE Assessment__c = :assessmentId
            ORDER BY CreatedDate ASC
        ];
    }

    private static AssessmentState buildState(Id assessmentId, List<RLM_HVAC_Finding__c> findings, Recommendation rec) {
        AssessmentState state = new AssessmentState();
        state.assessmentId = assessmentId;
        state.recommendation = rec;
        Map<Id, FindingView> views = new Map<Id, FindingView>();
        for (RLM_HVAC_Finding__c f : findings) {
            FindingView v = new FindingView();
            v.id = f.Id;
            v.name = f.Name;
            v.equipment = f.Equipment__c;
            v.component = f.Component__c;
            v.condition = f.Condition__c;
            v.urgency = f.Urgency__c;
            v.make = f.Make__c;
            v.modelNumber = f.Model_Number__c;
            v.serialNumber = f.Serial_Number__c;
            v.installYear = f.Install_Year__c == null ? null : f.Install_Year__c.intValue();
            v.reading = f.Reading__c;
            v.customerNote = f.Customer_Note__c;
            v.internalNote = f.Internal_Note__c;
            v.recommendedProduct = productFor(f, rec.planSku);
            v.recommendedProductName = PRODUCT_NAMES.get(v.recommendedProduct);
            v.workStatus = String.isBlank(f.Work_Status__c) ? 'Open' : f.Work_Status__c;
            v.workNote = f.Work_Note__c;
            v.completedOn = f.Completed_On__c;
            views.put(f.Id, v);
            state.findings.add(v);
        }
        if (!views.isEmpty()) {
            for (ContentDocumentLink link : [
                SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title,
                    ContentDocument.LatestPublishedVersionId,
                    ContentDocument.LatestPublishedVersion.RLM_HVAC_Photo_Stage__c,
                    ContentDocument.LatestPublishedVersion.VersionDataUrl
                FROM ContentDocumentLink
                WHERE LinkedEntityId IN :views.keySet()
                ORDER BY ContentDocument.CreatedDate ASC
            ]) {
                PhotoView p = new PhotoView();
                p.documentId = link.ContentDocumentId;
                p.versionId = link.ContentDocument.LatestPublishedVersionId;
                p.title = link.ContentDocument.Title;
                p.url = link.ContentDocument.LatestPublishedVersion.VersionDataUrl;
                p.stage = link.ContentDocument.LatestPublishedVersion.RLM_HVAC_Photo_Stage__c == 'After' ? 'After' : 'Before';
                FindingView v = views.get(link.LinkedEntityId);
                if (p.stage == 'After') {
                    v.afterPhotos.add(p);
                } else {
                    v.photos.add(p);
                }
            }
        }
        return state;
    }

    @TestVisible
    private static Recommendation recommend(List<RLM_HVAC_Finding__c> findings, RLM_HVAC_Assessment__c assessment) {
        Recommendation rec = new Recommendation();
        rec.systemType = assessment == null || String.isBlank(assessment.System_Type__c) ? 'AcFurnace' : assessment.System_Type__c;
        rec.systemCount = assessment == null || assessment.System_Count__c == null ? 1 : Math.max(1, assessment.System_Count__c.intValue());

        Integer maxRank = 1;
        Integer oldestYear;
        Boolean majorFailure = false;
        for (RLM_HVAC_Finding__c f : findings) {
            Integer rank = URGENCY_RANK.containsKey(f.Urgency__c) ? URGENCY_RANK.get(f.Urgency__c) : 1;
            if (isSafety(f)) {
                rank = 3;
            }
            maxRank = Math.max(maxRank, rank);
            if (f.Install_Year__c != null && (String.isBlank(f.Equipment__c) || MAIN_EQUIPMENT.contains(f.Equipment__c))) {
                Integer year = f.Install_Year__c.intValue();
                oldestYear = oldestYear == null ? year : Math.min(oldestYear, year);
            }
            if (f.Condition__c == 'Failed' && MAIN_EQUIPMENT.contains(f.Equipment__c)) {
                majorFailure = true;
            }
            if (isIaq(f)) {
                rec.includeIaq = true;
            } else if (isWaterHeater(f)) {
                rec.includeWaterHeater = true;
            }
            String repair = repairFor(f);
            if (repair != null && !rec.repairSkus.contains(repair)) {
                rec.repairSkus.add(repair);
            }
        }
        rec.urgency = maxRank == 3 ? 'Safety' : (maxRank == 2 ? 'Repair Soon' : 'Monitor');
        rec.safetyFlag = maxRank == 3;
        rec.oldestAge = oldestYear == null ? null : Date.today().year() - oldestYear;
        rec.equipmentAge = RLM_HVAC_FieldQuote.ageBand(rec.oldestAge);
        Boolean old = rec.oldestAge != null && rec.oldestAge >= REPLACEMENT_AGE;
        rec.replacementRecommended = old || (majorFailure && rec.oldestAge != null && rec.oldestAge > 10)
            || hasCrackedHeatExchanger(findings);

        if (rec.replacementRecommended || rec.safetyFlag || rec.repairSkus.size() >= 2) {
            rec.planSku = PREMIER;
        } else if (!rec.repairSkus.isEmpty() || rec.equipmentAge == '11to15' || rec.equipmentAge == 'Over15'
            || rec.systemCount > 1) {
            rec.planSku = PLUS;
        } else {
            rec.planSku = BASIC;
        }

        Map<String, Reason> bySku = new Map<String, Reason>();
        List<String> order = new List<String>{ rec.planSku, IAQ, WATER_HEATER };
        order.addAll(REPAIR_SKUS);
        for (String sku : order) {
            Reason r = new Reason();
            r.sku = sku;
            r.productName = PRODUCT_NAMES.get(sku);
            bySku.put(sku, r);
        }
        for (RLM_HVAC_Finding__c f : findings) {
            bySku.get(productFor(f, rec.planSku)).because.add(describe(f));
        }
        Reason plan = bySku.get(rec.planSku);
        if (rec.oldestAge != null) {
            plan.because.add(0, 'Oldest system is ' + rec.oldestAge + ' years old');
        }
        if (rec.systemCount > 1) {
            plan.because.add(rec.systemCount + ' systems in the home');
        }
        if (rec.replacementRecommended) {
            plan.because.add('Replacement recommended; Premier covers parts and labor until it is replaced');
        }
        if (plan.because.isEmpty()) {
            plan.because.add(rec.repairSkus.isEmpty()
                ? 'Equipment in good shape; two tune-ups a year keep it that way'
                : 'Repairs found today; the agreement adds priority response and repair discounts');
        }

        List<String> lines = new List<String>();
        for (String sku : order) {
            Reason r = bySku.get(sku);
            if (!r.because.isEmpty()) {
                rec.reasons.add(r);
                lines.add(r.productName + ': ' + String.join(r.because, '; '));
            }
        }
        rec.summary = String.join(lines, '\n');
        return rec;
    }

    private static String productFor(RLM_HVAC_Finding__c f, String planSku) {
        if (isIaq(f)) {
            return IAQ;
        }
        if (isWaterHeater(f)) {
            return WATER_HEATER;
        }
        String repair = repairFor(f);
        return repair == null ? planSku : repair;
    }

    /** One-time repair a finding calls for. Findings rated Monitor are noted, not repaired. */
    public static String repairFor(RLM_HVAC_Finding__c f) {
        if (f.Urgency__c == 'Monitor' && !isSafety(f)) {
            return null;
        }
        switch on f.Component__c {
            when 'Coil' {
                return f.Condition__c == 'Leaking' ? REFRIGERANT : COIL_CLEAN;
            }
            when 'Capacitor' {
                return CAPACITOR;
            }
            when 'Contactor' {
                return CONTACTOR;
            }
            when 'Condensate Drain' {
                return DRAIN_CLEAR;
            }
            when 'Refrigerant' {
                return REFRIGERANT;
            }
            when 'Blower Motor' {
                return BLOWER_MOTOR;
            }
        }
        return f.Condition__c == 'Low Charge' ? REFRIGERANT : null;
    }

    private static Boolean isIaq(RLM_HVAC_Finding__c f) {
        return f.Equipment__c == 'Indoor Air' || f.Condition__c == 'Allergies Noted'
            || (f.Component__c == 'Filter' && f.Condition__c == 'Clogged');
    }

    private static Boolean isWaterHeater(RLM_HVAC_Finding__c f) {
        return f.Equipment__c == 'Water Heater' || f.Condition__c == 'Sediment';
    }

    private static Boolean isSafety(RLM_HVAC_Finding__c f) {
        return f.Urgency__c == 'Safety'
            || (f.Component__c == 'Heat Exchanger' && f.Condition__c == 'Cracked')
            || (f.Component__c == 'Flue / Venting' && (f.Condition__c == 'Cracked' || f.Condition__c == 'Failed'));
    }

    private static Boolean hasCrackedHeatExchanger(List<RLM_HVAC_Finding__c> findings) {
        for (RLM_HVAC_Finding__c f : findings) {
            if (f.Component__c == 'Heat Exchanger' && f.Condition__c == 'Cracked') {
                return true;
            }
        }
        return false;
    }

    public static String describe(RLM_HVAC_Finding__c f) {
        List<String> what = new List<String>();
        if (String.isNotBlank(f.Component__c)) {
            what.add(f.Component__c.toLowerCase());
        }
        if (String.isNotBlank(f.Condition__c)) {
            what.add(f.Condition__c.toLowerCase());
        }
        String text = (String.isBlank(f.Equipment__c) ? 'System' : f.Equipment__c) + ': ' + String.join(what, ' ');
        if (String.isNotBlank(f.Reading__c)) {
            text += ', ' + f.Reading__c;
        }
        if (String.isNotBlank(f.Urgency__c) && f.Urgency__c != 'Monitor') {
            text += ' (' + f.Urgency__c.toLowerCase() + ')';
        }
        return text;
    }

    /** Links the system check to the Quote created from it, and puts the agreement explanation on the quote for the proposal. */
    public static void markQuoted(Id assessmentId, Id quoteId, String overrideReason) {
        update new RLM_HVAC_Assessment__c(
            Id = assessmentId,
            Quote__c = quoteId,
            Status__c = 'Quoted',
            Override_Reason__c = overrideReason
        );
        if (quoteId == null) {
            return;
        }
        String explanation = [SELECT Plan_Explanation__c FROM RLM_HVAC_Assessment__c WHERE Id = :assessmentId].Plan_Explanation__c;
        if (String.isNotBlank(explanation)) {
            update new Quote(Id = quoteId, RLM_HVAC_Plan_Explanation__c = explanation);
        }
    }
}

/**
 * Generative AI for the Brightline HVAC field app. Each feature fills one Prompt Builder template
 * (RLM_HVAC_* in unpackaged/post_hvac_ai) and falls back to the rules when Einstein isn't set up,
 * the call fails, or the reply can't be used. AI only drafts, suggests and explains: technicians
 * confirm findings, customers approve anything they pay for, and prices stay rule and zone based.
 *
 * The Einstein call lives in RLM_HVAC_EinsteinGenerator (post_hvac_ai) and is found by name, so
 * this bundle deploys and runs on the rules in orgs without generative AI.
 */
public with sharing class RLM_HVAC_AI {
    public static final String BRIEF_TEMPLATE = 'RLM_HVAC_Visit_Brief';
    public static final String PHOTO_TEMPLATE = 'RLM_HVAC_Photo_Finding';
    public static final String NOTES_TEMPLATE = 'RLM_HVAC_Notes_Finding';
    public static final String EXPLAIN_TEMPLATE = 'RLM_HVAC_Plan_Explanation';
    public static final String SUGGEST_TEMPLATE = 'RLM_HVAC_Product_Suggestions';
    public static final String SUMMARY_TEMPLATE = 'RLM_HVAC_Visit_Summary';
    private static final String EINSTEIN_GENERATOR = 'RLM_HVAC_EinsteinGenerator';
    private static final Integer MAX_PICKS = 3;

    public interface Generator {
        /** The model's reply for a prompt template. Inputs are keyed by the template input API name. */
        String generate(String templateName, Map<String, Object> inputs);
    }

    @TestVisible
    private static Generator generator {
        get {
            if (generator == null) {
                Type einstein = Type.forName(EINSTEIN_GENERATOR);
                generator = einstein == null ? null : (Generator) einstein.newInstance();
            }
            return generator;
        }
        set;
    }

    public class Brief {
        @AuraEnabled public String headline;
        @AuraEnabled public List<String> points = new List<String>();
        @AuraEnabled public List<String> lookFor = new List<String>();
        @AuraEnabled public Datetime generatedAt;
        @AuraEnabled public Boolean aiGenerated = false;
    }

    public class FindingSuggestion {
        @AuraEnabled public String equipment;
        @AuraEnabled public String component;
        @AuraEnabled public String condition;
        @AuraEnabled public String urgency;
        /** Read off the data plate in a photo, or heard in the notes. */
        @AuraEnabled public String make;
        @AuraEnabled public String modelNumber;
        @AuraEnabled public String serialNumber;
        @AuraEnabled public Integer installYear;
        /** A measurement, such as "capacitor 32 µF of 45" or "suction 98 psi". */
        @AuraEnabled public String reading;
        @AuraEnabled public String customerNote;
        @AuraEnabled public String internalNote;
        /** What the model saw in the photo, in a few words. */
        @AuraEnabled public String observation;
        @AuraEnabled public Boolean aiGenerated = false;
    }

    public class Pick {
        @AuraEnabled public String sku;
        @AuraEnabled public String reason;
        public Pick(String sku, String reason) {
            this.sku = sku;
            this.reason = reason;
        }
    }

    public class Option {
        public String sku;
        public String name;
        public String description;
        public Option(String sku, String name, String description) {
            this.sku = sku;
            this.name = name;
            this.description = description;
        }
    }

    public class Summary {
        @AuraEnabled public String text;
        @AuraEnabled public String emailedTo;
        @AuraEnabled public Datetime sentAt;
        @AuraEnabled public String emailError;
        @AuraEnabled public Boolean aiGenerated = false;
    }

    // ---------- 1. Pre-visit brief ----------

    /** The brief for the visit, generated once and kept on the work order so it still shows offline. */
    @AuraEnabled
    public static Brief getBrief(Id recordId, Boolean regenerate) {
        try {
            WorkOrder wo = workOrderFor(recordId);
            if (regenerate != true && String.isNotBlank(wo.RLM_HVAC_AI_Brief__c)) {
                Brief saved = savedBrief(wo.RLM_HVAC_AI_Brief__c);
                if (saved != null && (saved.aiGenerated == true || generator == null)) {
                    return saved;
                }
            }
            Facts facts = new Facts(wo);
            Brief brief = aiBrief(facts);
            if (brief == null) {
                brief = ruleBrief(facts);
            }
            brief.generatedAt = Datetime.now();
            update new WorkOrder(
                Id = wo.Id,
                RLM_HVAC_AI_Brief__c = JSON.serialize(brief),
                RLM_HVAC_AI_Brief_At__c = brief.generatedAt
            );
            return brief;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    private static Brief savedBrief(String body) {
        try {
            return (Brief) JSON.deserialize(body, Brief.class);
        } catch (Exception e) {
            return null;
        }
    }

    private static Brief aiBrief(Facts facts) {
        Map<String, Object> reply = generateJson(BRIEF_TEMPLATE, new Map<String, Object>{ 'Context' => facts.context() });
        if (reply == null || String.isBlank(asText(reply.get('headline')))) {
            return null;
        }
        Brief brief = new Brief();
        brief.aiGenerated = true;
        brief.headline = asText(reply.get('headline'));
        brief.points = asTexts(reply.get('points'), 5);
        brief.lookFor = asTexts(reply.get('lookFor'), 4);
        return brief;
    }

    private static Brief ruleBrief(Facts facts) {
        Brief brief = new Brief();
        brief.headline = (facts.isServiceVisit ? blankAs(facts.workType, 'Service visit') + ' for ' : 'System check for ') + facts.customer;
        if (String.isNotBlank(facts.reason)) {
            brief.points.add(facts.reason);
        }
        brief.points.add(facts.plans.isEmpty()
            ? 'No comfort agreement yet.'
            : 'On ' + String.join(facts.plans, ', ') + ' (' + money(facts.monthlyTotal) + '/mo).');
        if (!facts.pendingChanges.isEmpty()) {
            brief.points.add('Scheduled: ' + facts.pendingChanges[0] + '.');
        }
        if (!facts.pastVisits.isEmpty()) {
            brief.points.add('Last visit: ' + facts.pastVisits[0] + '.');
        }
        if (facts.openBalance > 0) {
            brief.points.add('Open balance ' + money(facts.openBalance) + ' on ' + facts.openInvoices.size()
                + (facts.openInvoices.size() == 1 ? ' invoice.' : ' invoices.'));
        }
        for (RLM_HVAC_Finding__c f : facts.findings) {
            if (f.Work_Status__c != 'Done' && brief.lookFor.size() < 4) {
                brief.lookFor.add(describe(f));
            }
        }
        if (brief.lookFor.isEmpty()) {
            brief.lookFor.add(facts.isServiceVisit
                ? 'Test capacitors and contactors, check the refrigerant charge, clear the condensate drain and change the filter.'
                : 'Photograph every data plate; note equipment age, filter condition and any gas or venting concerns.');
        }
        return brief;
    }

    // ---------- 2. Suggestions from photos ----------

    /**
     * What the model sees in a photo on a finding, for the technician to accept or edit: the component
     * and its condition, or the make, model, serial and install year read off a data plate.
     */
    @AuraEnabled
    public static FindingSuggestion suggestFromPhoto(Id findingId, Id documentId) {
        try {
            RLM_HVAC_Finding__c f = [
                SELECT Id, Equipment__c, Component__c, Condition__c, Urgency__c FROM RLM_HVAC_Finding__c WHERE Id = :findingId
            ];
            if ([SELECT COUNT() FROM ContentDocumentLink
                 WHERE LinkedEntityId = :findingId AND ContentDocumentId = :documentId] == 0) {
                throw new AIException('That photo is not on this finding.');
            }
            String context = 'Equipment: ' + blankAs(f.Equipment__c, 'unknown') + '\n'
                + 'Technician picked so far: component ' + blankAs(f.Component__c, 'none') + ', condition '
                + blankAs(f.Condition__c, 'none') + ', urgency ' + blankAs(f.Urgency__c, 'none') + '\n'
                + choices();
            Map<String, Object> reply = generateJson(PHOTO_TEMPLATE, new Map<String, Object>{
                'Photo' => new Map<String, String>{ 'id' => documentId },
                'Context' => context
            });
            return reply == null ? null : toSuggestion(reply, f.Equipment__c);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    // ---------- 3. Voice notes into findings ----------

    /** Turns what the technician dictated into a draft finding. Keyword matching when AI is unavailable. */
    @AuraEnabled
    public static FindingSuggestion parseNotes(String notes, String equipment) {
        try {
            if (String.isBlank(notes)) {
                throw new AIException('Say or type what you see first.');
            }
            Map<String, Object> reply = generateJson(NOTES_TEMPLATE, new Map<String, Object>{
                'Notes' => notes,
                'Context' => 'Equipment the technician is at: ' + blankAs(equipment, 'not picked') + '\n' + choices()
            });
            return reply == null ? keywordFinding(notes, equipment) : toSuggestion(reply, equipment);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @TestVisible
    private static FindingSuggestion keywordFinding(String notes, String equipment) {
        String text = words(notes);
        FindingSuggestion s = new FindingSuggestion();
        s.equipment = firstMatch(text, EQUIPMENT_WORDS, equipment);
        s.component = firstMatch(text, COMPONENT_WORDS, null);
        s.condition = firstMatch(text, CONDITION_WORDS, null);
        s.urgency = firstMatch(text, URGENCY_WORDS, 'Monitor');
        s.installYear = yearIn(notes);
        s.reading = readingIn(notes);
        s.customerNote = notes.trim();
        return s;
    }

    private static final Map<String, List<String>> EQUIPMENT_WORDS = new Map<String, List<String>>{
        'Heat Pump' => new List<String>{ 'heat pump' },
        'Outdoor Unit' => new List<String>{ 'condenser', 'outdoor unit', 'ac unit', 'a c unit', 'compressor' },
        'Furnace' => new List<String>{ 'furnace', 'burner', 'heat exchanger', 'flue', 'igniter' },
        'Air Handler' => new List<String>{ 'air handler', 'evaporator', 'blower' },
        'Boiler' => new List<String>{ 'boiler', 'radiator' },
        'Thermostat' => new List<String>{ 'thermostat' },
        'Ductwork' => new List<String>{ 'duct', 'register', 'vent ' },
        'Water Heater' => new List<String>{ 'water heater', 'tank' },
        'Indoor Air' => new List<String>{ 'allerg', 'dust', 'humidity', 'air quality', 'odor', 'smell' }
    };
    private static final Map<String, List<String>> COMPONENT_WORDS = new Map<String, List<String>>{
        'Capacitor' => new List<String>{ 'capacitor', ' cap ', 'microfarad', ' uf ', ' mfd' },
        'Contactor' => new List<String>{ 'contactor', 'pitted' },
        'Refrigerant' => new List<String>{ 'refrigerant', 'freon', 'r-410', 'r410', 'r-22', 'r22', 'charge', 'superheat', 'subcool' },
        'Coil' => new List<String>{ 'coil', 'fins' },
        'Blower Motor' => new List<String>{ 'blower motor', 'blower', 'motor' },
        'Condensate Drain' => new List<String>{ 'condensate', 'drain line', 'drain pan', 'float switch' },
        'Filter' => new List<String>{ 'filter' },
        'Heat Exchanger' => new List<String>{ 'heat exchanger' },
        'Flue / Venting' => new List<String>{ 'flue', 'venting', 'vent pipe', 'carbon monoxide', ' co ' },
        'Igniter' => new List<String>{ 'igniter', 'ignitor', 'flame sensor', 'pilot' },
        'Thermostat' => new List<String>{ 'thermostat' },
        'Airflow' => new List<String>{ 'airflow', 'static pressure', 'weak air' },
        'Tank' => new List<String>{ 'tank', 'anode' }
    };
    private static final Map<String, List<String>> CONDITION_WORDS = new Map<String, List<String>>{
        'Cracked' => new List<String>{ 'crack' },
        'Leaking' => new List<String>{ 'leak', 'oil spot', 'dripping' },
        'Low Charge' => new List<String>{ 'low charge', 'low on refrigerant', 'undercharged', 'low suction' },
        'Failed' => new List<String>{ 'failed', 'dead', 'not running', 'won t start', 'burnt', 'burned out' },
        'Clogged' => new List<String>{ 'clog', 'plugged', 'blocked', 'backed up' },
        'Dirty' => new List<String>{ 'dirty', 'dust', 'debris', 'cottonwood', 'grime' },
        'Worn' => new List<String>{ 'worn', 'weak', 'pitted', 'bulging', 'tired' },
        'Out of Range' => new List<String>{ 'out of range', 'out of spec', 'reading low', 'reading high', 'below rated' },
        'Sediment' => new List<String>{ 'sediment', 'rumbling', 'popping' },
        'Allergies Noted' => new List<String>{ 'allerg', 'asthma' },
        'Aging Equipment' => new List<String>{ 'original equipment', 'years old', 'end of life', 'aging', 'old unit' }
    };
    private static final Map<String, List<String>> URGENCY_WORDS = new Map<String, List<String>>{
        'Safety' => new List<String>{ 'safety', 'carbon monoxide', ' co ', 'gas leak', 'smell gas', 'heat exchanger crack', 'cracked heat exchanger' },
        'Repair Soon' => new List<String>{ 'repair', 'replace', 'failing', 'needs', 'should fix', 'won t last', 'soon' },
        'Monitor' => new List<String>{ 'monitor', 'keep an eye', 'fine for now', 'watch' }
    };

    /** A four-digit install year in the notes ("installed 2009", "a 2011 unit"), if it's a plausible one. */
    @TestVisible
    private static Integer yearIn(String notes) {
        Matcher m = Pattern.compile('\\b(19[89]\\d|20[0-4]\\d)\\b').matcher(blankAs(notes, ''));
        while (m.find()) {
            Integer year = Integer.valueOf(m.group(1));
            if (year <= Date.today().year()) {
                return year;
            }
        }
        return null;
    }

    /** A measurement in the notes: a number with an HVAC unit, and a few words around it. */
    @TestVisible
    private static String readingIn(String notes) {
        Matcher m = Pattern.compile('(?i)([a-z ]{0,20}?\\d+(?:\\.\\d+)?\\s*(?:µf|uf|mfd|psi|°f|degrees|amps?|volts?|inches|in\\.? wc|ppm)(?:\\s*(?:of|vs|rated)\\s*\\d+(?:\\.\\d+)?)?)')
            .matcher(blankAs(notes, ''));
        return m.find() ? m.group(1).trim().abbreviate(120) : null;
    }

    /** The model sometimes "suggests" a product while saying nothing supports it; those never reach the technician. */
    @TestVisible
    private static Boolean isUnsupported(String reason) {
        String text = ' ' + reason.toLowerCase() + ' ';
        for (String phrase : new List<String>{ ' no ', ' not ', ' none', 'may be', 'might', 'potential', 'consider', 'n\'t ' }) {
            if (text.contains(phrase)) {
                return true;
            }
        }
        return false;
    }

    /** A reason that names a component must name one the option actually repairs or covers. */
    @TestVisible
    private static Boolean covers(Option o, String reason) {
        Set<String> named = componentsIn(reason);
        if (named.isEmpty()) {
            return true;
        }
        named.retainAll(componentsIn(o.name + ' ' + o.description));
        return !named.isEmpty();
    }

    private static Set<String> componentsIn(String text) {
        Set<String> found = new Set<String>();
        String lower = words(text);
        for (String component : COMPONENT_WORDS.keySet()) {
            for (String word : COMPONENT_WORDS.get(component)) {
                if (lower.contains(word)) {
                    found.add(component);
                }
            }
        }
        if (lower.contains('tune-up') || lower.contains('tune up') || lower.contains('agreement')) {
            found.addAll(new List<String>{ 'Coil', 'Filter', 'Condensate Drain', 'Capacitor', 'Contactor' });
        }
        return found;
    }

    /** Lowercase with punctuation as spaces and padded, so keywords can anchor on word edges. */
    private static String words(String text) {
        return ' ' + blankAs(text, '').toLowerCase().replaceAll('[^a-z0-9\\- ]', ' ') + ' ';
    }

    private static String firstMatch(String text, Map<String, List<String>> words, String fallback) {
        for (String value : words.keySet()) {
            for (String word : words.get(value)) {
                if (text.contains(word)) {
                    return value;
                }
            }
        }
        return fallback;
    }

    // ---------- 4. Plain-language "why this agreement" ----------

    /**
     * Two friendly sentences on why the recommended agreement fits, written from the rules' reasons and
     * the findings. Kept on the system check until the recommendation changes, and on the quote for the proposal.
     */
    @AuraEnabled
    public static String explainPlan(Id assessmentId) {
        try {
            RLM_HVAC_Assessment__c assessment = [
                SELECT Id, Account__r.Name, Overall_Urgency__c, Equipment_Age__c, System_Type__c, System_Count__c,
                    Replacement_Recommended__c, Recommendation_Summary__c, Plan_Explanation__c,
                    Plan_Explanation_Basis__c, Quote__c
                FROM RLM_HVAC_Assessment__c WHERE Id = :assessmentId
            ];
            if (String.isNotBlank(assessment.Plan_Explanation__c)
                && assessment.Plan_Explanation_Basis__c != null
                && assessment.Plan_Explanation_Basis__c.equals(assessment.Recommendation_Summary__c)) {
                return assessment.Plan_Explanation__c;
            }
            List<RLM_HVAC_Finding__c> findings = findingsFor(new Set<Id>{ assessmentId });
            List<String> lines = new List<String>{
                'Customer: ' + assessment.Account__r?.Name,
                'Systems: ' + (assessment.System_Count__c == null ? 1 : assessment.System_Count__c.intValue())
                    + ' (' + blankAs(assessment.System_Type__c, 'AcFurnace') + '), equipment age band '
                    + blankAs(assessment.Equipment_Age__c, 'unknown'),
                'Overall urgency: ' + blankAs(assessment.Overall_Urgency__c, 'Monitor'),
                'Replacement recommended: ' + (assessment.Replacement_Recommended__c == true ? 'yes' : 'no'),
                'Recommended products and the findings behind them:',
                blankAs(assessment.Recommendation_Summary__c, 'Comfort Basic: equipment in good shape')
            };
            lines.add('Findings:');
            lines.addAll(findingLines(findings, false));
            String text = generate(EXPLAIN_TEMPLATE, new Map<String, Object>{ 'Context' => String.join(lines, '\n') });
            Boolean ai = text != null;
            if (!ai) {
                text = ruleExplanation(assessment.Recommendation_Summary__c);
            }
            update new RLM_HVAC_Assessment__c(
                Id = assessment.Id,
                Plan_Explanation__c = text,
                Plan_Explanation_Basis__c = ai ? assessment.Recommendation_Summary__c : null
            );
            if (assessment.Quote__c != null) {
                update new Quote(Id = assessment.Quote__c, RLM_HVAC_Plan_Explanation__c = text);
            }
            return text;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @TestVisible
    private static String ruleExplanation(String recommendationSummary) {
        if (String.isBlank(recommendationSummary)) {
            return 'Your equipment is in good shape today, so we recommend Comfort Basic to keep it that way with a spring and fall tune-up.';
        }
        List<String> sentences = new List<String>();
        for (String line : recommendationSummary.split('\n')) {
            String product = line.substringBefore(':').trim();
            String because = line.substringAfter(':').trim();
            sentences.add(sentences.isEmpty()
                ? 'Based on what we found today, we recommend ' + product + ': ' + because + '.'
                : 'We also recommend ' + product + ' for ' + because + '.');
        }
        return String.join(sentences, ' ');
    }

    // ---------- 5. Smarter Find & Add and Change the agreement ----------

    /**
     * Products the findings' notes call for beyond the fixed rules. Only SKUs from options come
     * back, so the caller prices them as usual and the customer still approves.
     */
    public static List<Pick> suggestProducts(Id accountId, List<Option> options, String kind) {
        List<Pick> picks = new List<Pick>();
        if (options.isEmpty() || accountId == null) {
            return picks;
        }
        List<RLM_HVAC_Finding__c> findings = findingsFor(assessmentsFor(accountId));
        if (findings.isEmpty()) {
            return picks;
        }
        Map<String, Option> bySku = new Map<String, Option>();
        List<String> lines = new List<String>{ 'Choose from these ' + kind + ' (SKU | name | what it covers):' };
        for (Option o : options) {
            bySku.put(o.sku, o);
            lines.add(o.sku + ' | ' + o.name + ' | ' + blankAs(o.description, ''));
        }
        lines.add('Findings and notes from this customer\'s visits:');
        lines.addAll(findingLines(findings, true));
        Map<String, Object> reply = generateJson(SUGGEST_TEMPLATE, new Map<String, Object>{ 'Context' => String.join(lines, '\n') });
        Object suggestions = reply == null ? null : reply.get('suggestions');
        if (!(suggestions instanceof List<Object>)) {
            return picks;
        }
        Set<String> seen = new Set<String>();
        for (Object item : (List<Object>) suggestions) {
            if (!(item instanceof Map<String, Object>) || picks.size() == MAX_PICKS) {
                continue;
            }
            Map<String, Object> m = (Map<String, Object>) item;
            String sku = asText(m.get('sku'));
            String reason = asText(m.get('reason'));
            if (sku != null && bySku.containsKey(sku) && String.isNotBlank(reason) && !isUnsupported(reason)
                    && covers(bySku.get(sku), reason) && seen.add(sku)) {
                picks.add(new Pick(sku, reason.abbreviate(160)));
            }
        }
        return picks;
    }

    // ---------- 6. Post-visit summary ----------

    /** Writes the visit summary once the work order is complete, saves it on the work order and emails the customer. */
    @AuraEnabled
    public static Summary summarizeVisit(Id recordId) {
        try {
            WorkOrder wo = workOrderFor(recordId);
            if (wo.Status != 'Completed') {
                throw new AIException('Complete the visit before sending the summary.');
            }
            Contact contact = contactFor(wo);
            Summary summary = new Summary();
            if (String.isNotBlank(wo.RLM_HVAC_Visit_Summary__c) && wo.RLM_HVAC_Summary_Sent_At__c != null) {
                summary.text = wo.RLM_HVAC_Visit_Summary__c;
                summary.sentAt = wo.RLM_HVAC_Summary_Sent_At__c;
                summary.emailedTo = contact?.Email;
                summary.aiGenerated = generator != null;
                return summary;
            }
            Facts facts = new Facts(wo);
            String context = facts.visitContext(contact?.FirstName);
            summary.text = generate(SUMMARY_TEMPLATE, new Map<String, Object>{ 'Context' => context });
            summary.aiGenerated = summary.text != null;
            if (summary.text == null) {
                summary.text = ruleSummary(facts, contact?.FirstName);
            }
            WorkOrder change = new WorkOrder(Id = wo.Id, RLM_HVAC_Visit_Summary__c = summary.text.abbreviate(8000));
            if (contact != null && String.isNotBlank(contact.Email)) {
                try {
                    Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
                    email.setTargetObjectId(contact.Id);
                    email.setSubject('Your Brightline visit summary · ' + wo.WorkOrderNumber);
                    email.setPlainTextBody(summary.text);
                    email.setSaveAsActivity(true);
                    Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });
                    summary.emailedTo = contact.Email;
                    summary.sentAt = Datetime.now();
                    change.RLM_HVAC_Summary_Sent_At__c = summary.sentAt;
                } catch (Exception emailFailed) {
                    summary.emailError = 'Saved on the work order, but the email could not be sent: ' + emailFailed.getMessage();
                }
            } else {
                summary.emailError = 'Saved on the work order. The customer has no email address.';
            }
            update change;
            return summary;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    private static String ruleSummary(Facts facts, String firstName) {
        List<String> lines = new List<String>{ 'Hi ' + blankAs(firstName, 'there') + ',', '' };
        lines.add('Thanks for having us out today. Here\'s a summary of visit ' + facts.workOrderNumber + '.');
        List<String> done = new List<String>();
        List<String> open = new List<String>();
        for (RLM_HVAC_Finding__c f : facts.findings) {
            if (f.Work_Status__c == 'Done') {
                done.add(describe(f));
            } else {
                open.add(describe(f));
            }
        }
        if (!facts.stepsDone.isEmpty()) {
            lines.add('');
            lines.add('Your tune-up:');
            for (String t : facts.stepsDone) {
                lines.add('- ' + t);
            }
        }
        if (!done.isEmpty()) {
            lines.add('');
            lines.add('What we took care of:');
            for (String t : done) {
                lines.add('- ' + t);
            }
        }
        if (!facts.visitAddOns.isEmpty()) {
            lines.add('');
            lines.add('Repairs you approved: ' + String.join(facts.visitAddOns, ', ') + '.');
        }
        if (!facts.visitPlanChanges.isEmpty()) {
            lines.add('Agreement changes you approved: ' + String.join(facts.visitPlanChanges, '; ') + '.');
        }
        if (!open.isEmpty() && facts.isServiceVisit) {
            lines.add('');
            lines.add('We\'ll keep an eye on: ' + String.join(open, '; ') + '.');
        }
        if (facts.nextVisit != null) {
            lines.add('');
            lines.add('Your next visit is ' + facts.nextVisitText() + '.');
        }
        lines.add('');
        lines.add('Questions? Just reply to this email.');
        lines.add('Brightline Home Comfort');
        return String.join(lines, '\n');
    }

    // ---------- facts about a visit and its customer ----------

    private class Facts {
        WorkOrder wo;
        String customer;
        String workOrderNumber;
        Boolean isServiceVisit;
        String workType;
        String reason;
        List<String> plans = new List<String>();
        Decimal monthlyTotal = 0;
        List<String> pendingChanges = new List<String>();
        List<String> pastVisits = new List<String>();
        List<String> recentAddOns = new List<String>();
        List<String> openInvoices = new List<String>();
        Decimal openBalance = 0;
        List<RLM_HVAC_Finding__c> findings = new List<RLM_HVAC_Finding__c>();
        List<String> visitAddOns = new List<String>();
        List<String> visitPlanChanges = new List<String>();
        List<String> stepsDone = new List<String>();
        Datetime nextVisit;
        String nextVisitType;

        Facts(WorkOrder wo) {
            this.wo = wo;
            customer = wo.Contact?.Name != null ? wo.Contact.Name : wo.Account?.Name;
            workOrderNumber = wo.WorkOrderNumber;
            workType = wo.WorkType?.Name;
            isServiceVisit = wo.RLM_Order__c != null || workType != null
                && !workType.containsIgnoreCase('system check');
            reason = String.isNotBlank(wo.Description) ? wo.Description.abbreviate(300) : wo.Subject;
            if (wo.AccountId == null) {
                return;
            }
            loadPlans();
            String changePattern = RLM_HVAC_PlanChange.ORDER_NAME_PREFIX + ':%';
            for (Order o : [
                SELECT Name, EffectiveDate, Description FROM Order
                WHERE AccountId = :wo.AccountId AND Name LIKE :changePattern AND Status = 'Activated'
                ORDER BY EffectiveDate DESC LIMIT 10
            ]) {
                String text = o.Name.removeStart(RLM_HVAC_PlanChange.ORDER_NAME_PREFIX + ':').trim() + ' from ' + o.EffectiveDate.format();
                if (o.EffectiveDate > Date.today()) {
                    pendingChanges.add(text);
                }
                if (o.Description != null && o.Description.contains('work order ' + wo.WorkOrderNumber)) {
                    visitPlanChanges.add(text);
                }
            }
            for (WorkOrder past : [
                SELECT WorkOrderNumber, Subject, WorkType.Name, EndDate, LastModifiedDate, RLM_HVAC_Visit_Summary__c
                FROM WorkOrder
                WHERE AccountId = :wo.AccountId AND Id != :wo.Id AND Status = 'Completed'
                ORDER BY LastModifiedDate DESC LIMIT 4
            ]) {
                Datetime done = past.EndDate != null ? past.EndDate : past.LastModifiedDate;
                String text = blankAs(past.WorkType?.Name, blankAs(past.Subject, 'Visit')) + ' on ' + done.format('MMM d');
                if (String.isNotBlank(past.RLM_HVAC_Visit_Summary__c)) {
                    text += ': ' + past.RLM_HVAC_Visit_Summary__c.replaceAll('\\s+', ' ').abbreviate(240);
                }
                pastVisits.add(text);
            }
            for (WorkOrderLineItem line : [
                SELECT Subject, UnitPrice, WorkOrderId, RLM_HVAC_Approved_At__c FROM WorkOrderLineItem
                WHERE WorkOrder.AccountId = :wo.AccountId AND RLM_HVAC_Approved_At__c != null
                ORDER BY RLM_HVAC_Approved_At__c DESC LIMIT 6
            ]) {
                String text = line.Subject + ' (' + money(line.UnitPrice) + ')';
                if (line.WorkOrderId == wo.Id) {
                    visitAddOns.add(text);
                } else {
                    recentAddOns.add(text + ' on ' + line.RLM_HVAC_Approved_At__c.format('MMM d'));
                }
            }
            for (Invoice inv : [
                SELECT DocumentNumber, Balance, DueDate FROM Invoice
                WHERE BillingAccountId = :wo.AccountId AND Status = 'Posted' AND Balance > 0
                ORDER BY DueDate ASC LIMIT 5
            ]) {
                openInvoices.add(inv.DocumentNumber + ' ' + money(inv.Balance)
                    + (inv.DueDate == null ? '' : ' due ' + inv.DueDate.format()));
                openBalance += inv.Balance;
            }
            stepsDone = RLM_HVAC_Assessment.completedSteps(wo.Id);
            findings = findingsFor(wo.RLM_HVAC_Assessment__c != null
                ? new Set<Id>{ wo.RLM_HVAC_Assessment__c } : assessmentsFor(wo.AccountId));
            for (ServiceAppointment sa : [
                SELECT SchedStartTime, WorkType.Name FROM ServiceAppointment
                WHERE AccountId = :wo.AccountId AND ParentRecordId != :wo.Id AND SchedStartTime > :Datetime.now()
                    AND Status NOT IN ('Completed', 'Canceled', 'Cannot Complete')
                ORDER BY SchedStartTime ASC LIMIT 1
            ]) {
                nextVisit = sa.SchedStartTime;
                nextVisitType = sa.WorkType?.Name;
            }
            if (nextVisit == null) {
                // Visits generated from the agreement aren't booked yet; they have a suggested day.
                for (WorkOrder upcoming : [
                    SELECT SuggestedMaintenanceDate, WorkType.Name FROM WorkOrder
                    WHERE AccountId = :wo.AccountId AND Id != :wo.Id AND Status = 'New'
                        AND SuggestedMaintenanceDate >= :Date.today()
                    ORDER BY SuggestedMaintenanceDate ASC LIMIT 1
                ]) {
                    nextVisit = Datetime.newInstance(upcoming.SuggestedMaintenanceDate, Time.newInstance(12, 0, 0, 0));
                    nextVisitType = upcoming.WorkType?.Name;
                }
            }
        }

        String nextVisitText() {
            return nextVisit == null ? null
                : nextVisit.format('EEEE, MMMM d') + (String.isBlank(nextVisitType) ? '' : ' (' + nextVisitType + ')');
        }

        void loadPlans() {
            Set<Id> seen = new Set<Id>();
            Map<String, Integer> countByName = new Map<String, Integer>();
            Datetime now = Datetime.now();
            for (AssetStatePeriod period : [
                SELECT AssetId, Asset.Name, Asset.Product2.Name, Quantity, Mrr, Amount, StartDate, EndDate
                FROM AssetStatePeriod
                WHERE Asset.AccountId = :wo.AccountId AND StartDate <= :now
                ORDER BY StartDate DESC
            ]) {
                if (!seen.add(period.AssetId) || period.Quantity == null || period.Quantity <= 0
                    || (period.EndDate != null && period.EndDate < now)) {
                    continue;
                }
                if (period.Mrr == null || period.Mrr <= 0) {
                    continue;
                }
                String name = blankAs(period.Asset.Product2?.Name, period.Asset.Name);
                Integer count = countByName.get(name);
                countByName.put(name, count == null ? 1 : count + 1);
                monthlyTotal += period.Mrr;
            }
            for (String name : countByName.keySet()) {
                Integer count = countByName.get(name);
                plans.add(count > 1 ? name + ' ×' + count : name);
            }
        }

        /** Everything the brief can draw on, as labeled lines. */
        String context() {
            List<String> lines = new List<String>{
                'Customer: ' + customer,
                'Visit: ' + (isServiceVisit ? blankAs(workType, 'service visit') : 'system check') + ' ' + workOrderNumber,
                'Why they called / work order notes: ' + blankAs(reason, 'none'),
                'Comfort agreement: ' + (plans.isEmpty() ? 'none' : String.join(plans, ', ') + ' (' + money(monthlyTotal) + '/mo)'),
                'Scheduled agreement changes: ' + (pendingChanges.isEmpty() ? 'none' : String.join(pendingChanges, '; ')),
                'Open invoices: ' + (openInvoices.isEmpty() ? 'none' : String.join(openInvoices, '; ')),
                'Recent one-time repairs: ' + (recentAddOns.isEmpty() ? 'none' : String.join(recentAddOns, '; ')),
                'Past visits:'
            };
            lines.addAll(pastVisits.isEmpty() ? new List<String>{ '- none' } : bullets(pastVisits));
            lines.add('Equipment and findings from system checks and visits:');
            lines.addAll(findingLines(findings, true));
            return String.join(lines, '\n');
        }

        /** What happened on this visit, for the summary. */
        String visitContext(String firstName) {
            List<String> lines = new List<String>{
                'Customer first name: ' + blankAs(firstName, 'there'),
                'Visit: ' + (isServiceVisit ? blankAs(workType, 'service visit') : 'system check') + ' ' + workOrderNumber,
                'Agreement now: ' + (plans.isEmpty() ? 'none' : String.join(plans, ', ')),
                'Repairs approved today: ' + (visitAddOns.isEmpty() ? 'none' : String.join(visitAddOns, ', ')),
                'Agreement changes approved today: ' + (visitPlanChanges.isEmpty() ? 'none' : String.join(visitPlanChanges, '; ')),
                'Next visit: ' + blankAs(nextVisitText(), 'not scheduled yet'),
                'Tune-up steps done:'
            };
            lines.addAll(stepsDone.isEmpty() ? new List<String>{ '- none' } : bullets(stepsDone));
            List<RLM_HVAC_Finding__c> fixed = new List<RLM_HVAC_Finding__c>();
            List<RLM_HVAC_Finding__c> open = new List<RLM_HVAC_Finding__c>();
            for (RLM_HVAC_Finding__c f : findings) {
                if (f.Work_Status__c == 'Done') {
                    fixed.add(f);
                } else {
                    open.add(f);
                }
            }
            lines.add('Found and fixed on this visit:');
            lines.addAll(fixed.isEmpty() ? new List<String>{ '- none' } : findingLines(fixed, false));
            lines.add('Still open, to keep an eye on:');
            lines.addAll(open.isEmpty() ? new List<String>{ '- none' } : findingLines(open, false));
            return String.join(lines, '\n');
        }
    }

    // ---------- shared helpers ----------

    @TestVisible
    private static String generate(String templateName, Map<String, Object> inputs) {
        if (generator == null) {
            return null;
        }
        try {
            String text = generator.generate(templateName, inputs);
            return String.isBlank(text) ? null : text.trim();
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, templateName + ' failed, using the rules: ' + e.getMessage());
            return null;
        }
    }

    /** The first JSON object in the reply; models sometimes wrap it in a code fence. */
    @TestVisible
    private static Map<String, Object> generateJson(String templateName, Map<String, Object> inputs) {
        String text = generate(templateName, inputs);
        if (text == null) {
            return null;
        }
        Integer start = text.indexOf('{');
        Integer finish = text.lastIndexOf('}');
        if (start < 0 || finish <= start) {
            return null;
        }
        try {
            Object parsed = JSON.deserializeUntyped(text.substring(start, finish + 1));
            return parsed instanceof Map<String, Object> ? (Map<String, Object>) parsed : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static FindingSuggestion toSuggestion(Map<String, Object> reply, String equipment) {
        FindingSuggestion s = new FindingSuggestion();
        s.aiGenerated = true;
        s.equipment = allowed(reply.get('equipment'), RLM_HVAC_Finding__c.Equipment__c, equipment);
        s.component = allowed(reply.get('component'), RLM_HVAC_Finding__c.Component__c, null);
        s.condition = allowed(reply.get('condition'), RLM_HVAC_Finding__c.Condition__c, null);
        s.urgency = allowed(reply.get('urgency'), RLM_HVAC_Finding__c.Urgency__c, 'Monitor');
        s.make = abbreviated(reply.get('make'), 60);
        s.modelNumber = abbreviated(reply.get('modelNumber'), 60);
        s.serialNumber = abbreviated(reply.get('serialNumber'), 60);
        s.installYear = yearIn(asText(reply.get('installYear')));
        s.reading = abbreviated(reply.get('reading'), 120);
        s.customerNote = asText(reply.get('customerNote'));
        s.internalNote = asText(reply.get('internalNote'));
        s.observation = asText(reply.get('observation'));
        return s;
    }

    private static String abbreviated(Object value, Integer max) {
        String text = asText(value);
        return text == null ? null : text.abbreviate(max);
    }

    /** The picklist value matching the reply, ignoring case; fallback when there's no match. */
    private static String allowed(Object value, Schema.SObjectField field, String fallback) {
        String text = asText(value);
        if (text != null) {
            for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
                if (entry.isActive() && entry.getValue().equalsIgnoreCase(text)) {
                    return entry.getValue();
                }
            }
        }
        return fallback;
    }

    private static String choices() {
        return 'Allowed equipment values: ' + values(RLM_HVAC_Finding__c.Equipment__c) + '\n'
            + 'Allowed component values: ' + values(RLM_HVAC_Finding__c.Component__c) + '\n'
            + 'Allowed condition values: ' + values(RLM_HVAC_Finding__c.Condition__c) + '\n'
            + 'Allowed urgency values: ' + values(RLM_HVAC_Finding__c.Urgency__c);
    }

    private static String values(Schema.SObjectField field) {
        List<String> result = new List<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                result.add(entry.getValue());
            }
        }
        return String.join(result, ', ');
    }

    private static Set<Id> assessmentsFor(Id accountId) {
        return new Map<Id, RLM_HVAC_Assessment__c>([
            SELECT Id FROM RLM_HVAC_Assessment__c WHERE Account__c = :accountId ORDER BY CreatedDate DESC LIMIT 3
        ]).keySet();
    }

    private static List<RLM_HVAC_Finding__c> findingsFor(Set<Id> assessmentIds) {
        return [
            SELECT Id, Equipment__c, Component__c, Condition__c, Urgency__c, Customer_Note__c, Internal_Note__c,
                Make__c, Model_Number__c, Serial_Number__c, Install_Year__c, Reading__c,
                Work_Status__c, Work_Note__c, Completed_On__c
            FROM RLM_HVAC_Finding__c WHERE Assessment__c IN :assessmentIds
            ORDER BY CreatedDate DESC LIMIT 20
        ];
    }

    private static List<String> findingLines(List<RLM_HVAC_Finding__c> findings, Boolean includeInternal) {
        if (findings.isEmpty()) {
            return new List<String>{ '- none' };
        }
        List<String> lines = new List<String>();
        for (RLM_HVAC_Finding__c f : findings) {
            String line = '- ' + describe(f) + '; work: ' + blankAs(f.Work_Status__c, 'Open');
            if (String.isNotBlank(f.Make__c) || f.Install_Year__c != null) {
                line += '; equipment: ' + String.join(new List<String>{ blankAs(f.Make__c, ''), blankAs(f.Model_Number__c, ''),
                    f.Install_Year__c == null ? '' : 'installed ' + f.Install_Year__c.intValue() }, ' ').normalizeSpace();
            }
            if (String.isNotBlank(f.Customer_Note__c)) {
                line += '; note: ' + f.Customer_Note__c;
            }
            if (includeInternal && String.isNotBlank(f.Internal_Note__c)) {
                line += '; technician note: ' + f.Internal_Note__c;
            }
            if (String.isNotBlank(f.Work_Note__c)) {
                line += '; work note: ' + f.Work_Note__c;
            }
            lines.add(line.abbreviate(400));
        }
        return lines;
    }

    private static String describe(RLM_HVAC_Finding__c f) {
        return RLM_HVAC_Assessment.describe(f);
    }

    private static List<String> bullets(List<String> items) {
        List<String> result = new List<String>();
        for (String item : items) {
            result.add('- ' + item);
        }
        return result;
    }

    private static Contact contactFor(WorkOrder wo) {
        if (wo.ContactId != null && String.isNotBlank(wo.Contact.Email)) {
            return wo.Contact;
        }
        List<Contact> contacts = [
            SELECT Id, FirstName, Name, Email FROM Contact
            WHERE AccountId = :wo.AccountId AND Email != null ORDER BY CreatedDate ASC LIMIT 1
        ];
        return contacts.isEmpty() ? wo.Contact : contacts[0];
    }

    private static WorkOrder workOrderFor(Id recordId) {
        if (recordId == null) {
            throw new AIException('Open this from a service appointment or work order.');
        }
        Id workOrderId = recordId;
        if (recordId.getSobjectType() == ServiceAppointment.SObjectType) {
            workOrderId = [SELECT ParentRecordId FROM ServiceAppointment WHERE Id = :recordId].ParentRecordId;
        }
        if (workOrderId == null || workOrderId.getSobjectType() != WorkOrder.SObjectType) {
            throw new AIException('Open this from a service appointment or work order.');
        }
        return [
            SELECT Id, WorkOrderNumber, Subject, Description, Status, AccountId, Account.Name, ContactId,
                Contact.Name, Contact.FirstName, Contact.Email, WorkType.Name, RLM_Order__c, RLM_HVAC_Assessment__c,
                RLM_HVAC_AI_Brief__c, RLM_HVAC_Visit_Summary__c, RLM_HVAC_Summary_Sent_At__c
            FROM WorkOrder WHERE Id = :workOrderId
        ];
    }

    private static String asText(Object value) {
        if (value == null) {
            return null;
        }
        String text = String.valueOf(value).trim();
        return String.isBlank(text) || text.equalsIgnoreCase('null') ? null : text;
    }

    private static List<String> asTexts(Object value, Integer max) {
        List<String> result = new List<String>();
        if (value instanceof List<Object>) {
            for (Object item : (List<Object>) value) {
                String text = asText(item);
                if (text != null && result.size() < max) {
                    result.add(text);
                }
            }
        }
        return result;
    }

    private static String blankAs(String value, String fallback) {
        return String.isBlank(value) ? fallback : value;
    }

    private static String money(Decimal value) {
        Decimal amount = value == null ? 0 : value.setScale(2);
        return '$' + (amount == amount.round(System.RoundingMode.DOWN) ? String.valueOf(amount.intValue()) : String.valueOf(amount));
    }

    public class AIException extends Exception {}

    private static AuraHandledException auraError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }
}

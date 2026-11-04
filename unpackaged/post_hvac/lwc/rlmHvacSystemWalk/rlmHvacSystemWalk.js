import { LightningElement, api } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';
import getState from '@salesforce/apex/RLM_HVAC_Assessment.getState';
import saveFinding from '@salesforce/apex/RLM_HVAC_Assessment.saveFinding';
import saveSystems from '@salesforce/apex/RLM_HVAC_Assessment.saveSystems';
import deleteFinding from '@salesforce/apex/RLM_HVAC_Assessment.deleteFinding';
import suggestFromPhoto from '@salesforce/apex/RLM_HVAC_AI.suggestFromPhoto';
import parseNotes from '@salesforce/apex/RLM_HVAC_AI.parseNotes';

const EQUIPMENT = [
    { value: 'Outdoor Unit', icon: 'utility:home', hint: 'Condenser coil, capacitor, contactor, refrigerant', plate: true },
    { value: 'Furnace', icon: 'utility:flow', hint: 'Heat exchanger, igniter, flue, blower', plate: true },
    { value: 'Air Handler', icon: 'utility:sync', hint: 'Evaporator coil, blower motor, drain', plate: true },
    { value: 'Heat Pump', icon: 'utility:refresh', hint: 'Coil, defrost, refrigerant', plate: true },
    { value: 'Boiler', icon: 'utility:rotate', hint: 'Pressure, venting, circulator', plate: true },
    { value: 'Thermostat', icon: 'utility:settings', hint: 'Wiring, calibration, schedule', plate: false },
    { value: 'Ductwork', icon: 'utility:layers', hint: 'Leaks, insulation, airflow', plate: false },
    { value: 'Water Heater', icon: 'utility:water', hint: 'Tank, anode, sediment, venting', plate: true },
    { value: 'Indoor Air', icon: 'utility:world', hint: 'Filters, humidity, allergies', plate: false }
];
const COMPONENTS = [
    'Coil', 'Capacitor', 'Contactor', 'Refrigerant', 'Blower Motor', 'Condensate Drain', 'Filter',
    'Heat Exchanger', 'Flue / Venting', 'Igniter', 'Thermostat', 'Airflow', 'Tank', 'Other'
];
const CONDITIONS = [
    'Dirty', 'Worn', 'Failed', 'Leaking', 'Low Charge', 'Clogged', 'Cracked', 'Out of Range',
    'Aging Equipment', 'Allergies Noted', 'Sediment'
];
const URGENCIES = [
    { value: 'Monitor', tone: 'light' },
    { value: 'Repair Soon', tone: 'moderate' },
    { value: 'Safety', tone: 'heavy' }
];
const SYSTEM_TYPES = [
    { value: 'AcFurnace', label: 'AC + furnace' },
    { value: 'HeatPump', label: 'Heat pump' },
    { value: 'Boiler', label: 'Boiler' }
];
const MAX_SYSTEMS = 4;
const toneFor = (urgency) => (URGENCIES.find((u) => u.value === urgency) || URGENCIES[0]).tone;

const emptyDraft = (equipment) => ({
    id: null,
    equipment,
    component: null,
    condition: null,
    urgency: 'Monitor',
    make: '',
    modelNumber: '',
    serialNumber: '',
    installYear: null,
    reading: '',
    customerNote: '',
    internalNote: ''
});

export default class RlmHvacSystemWalk extends LightningElement {
    @api assessmentId;
    @api accountName;
    @api serviceAddress;

    @api planSku;
    @api recommendationJson;
    @api findingCount;

    findings = [];
    recommendation;
    clearEquipment = new Set();
    activeEquipment;
    draft;
    saving = false;
    loading = true;
    error;
    viewing;
    /** Einstein's read of the latest photo on each finding, by finding id, until applied or dismissed. */
    photoSuggestions = {};
    dictation = '';
    parsing = false;
    filledBy;

    connectedCallback() {
        this.load();
    }

    async load() {
        try {
            this.apply(await getState({ assessmentId: this.assessmentId }));
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.loading = false;
        }
    }

    apply(state) {
        this.findings = state.findings || [];
        this.recommendation = state.recommendation;
        this.error = undefined;
        const rec = this.recommendation || {};
        this.emit('planSku', rec.planSku);
        this.emit('recommendationJson', JSON.stringify(rec));
        this.emit('findingCount', this.findings.length);
    }

    emit(name, value) {
        this.dispatchEvent(new FlowAttributeChangeEvent(name, value));
    }

    message(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong';
    }

    // ---------- the home's systems ----------
    get systemType() {
        return (this.recommendation && this.recommendation.systemType) || 'AcFurnace';
    }

    get systemCount() {
        return (this.recommendation && this.recommendation.systemCount) || 1;
    }

    get systemTypeOptions() {
        return SYSTEM_TYPES.map((t) => ({
            ...t,
            cls: t.value === this.systemType ? 'chip selected' : 'chip',
            ariaPressed: t.value === this.systemType ? 'true' : 'false'
        }));
    }

    get systemCountLabel() {
        return this.systemCount === 1 ? '1 system' : `${this.systemCount} systems`;
    }

    get cannotRemoveSystem() {
        return this.saving || this.systemCount <= 1;
    }

    get cannotAddSystem() {
        return this.saving || this.systemCount >= MAX_SYSTEMS;
    }

    pickSystemType(event) {
        this.updateSystems(event.currentTarget.dataset.value, this.systemCount);
    }

    addSystem() {
        this.updateSystems(this.systemType, this.systemCount + 1);
    }

    removeSystem() {
        this.updateSystems(this.systemType, this.systemCount - 1);
    }

    async updateSystems(systemType, systemCount) {
        this.saving = true;
        try {
            this.apply(await saveSystems({ assessmentId: this.assessmentId, systemType, systemCount }));
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.saving = false;
        }
    }

    // ---------- equipment ----------
    get equipment() {
        return EQUIPMENT.map((z) => {
            const count = this.findings.filter((f) => f.equipment === z.value).length;
            const clear = this.clearEquipment.has(z.value);
            let status = 'Not checked';
            let tone = 'todo';
            if (count) {
                status = `${count} finding${count === 1 ? '' : 's'}`;
                tone = 'found';
            } else if (clear) {
                status = 'Good';
                tone = 'clear';
            }
            const active = z.value === this.activeEquipment;
            return {
                ...z,
                status,
                cardClass: `zone-card ${tone}${active ? ' active' : ''}`,
                ariaPressed: active ? 'true' : 'false'
            };
        });
    }

    get checkedCount() {
        return EQUIPMENT.filter(
            (z) => this.clearEquipment.has(z.value) || this.findings.some((f) => f.equipment === z.value)
        ).length;
    }

    get equipmentTotal() {
        return EQUIPMENT.length;
    }

    get progressStyle() {
        return `width: ${Math.round((this.checkedCount / EQUIPMENT.length) * 100)}%`;
    }

    get hasActiveEquipment() {
        return !!this.activeEquipment;
    }

    get activeEquipmentHint() {
        const z = EQUIPMENT.find((x) => x.value === this.activeEquipment);
        return z ? z.hint : '';
    }

    get showPlate() {
        const z = EQUIPMENT.find((x) => x.value === (this.draft && this.draft.equipment));
        return !!(z && z.plate);
    }

    get activeFindings() {
        return this.findings
            .filter((f) => f.equipment === this.activeEquipment)
            .map((f) => ({
                ...f,
                title: [f.component, f.condition].filter(Boolean).join(' · ') || 'Data plate',
                plate: [f.make, f.modelNumber, f.installYear ? `${f.installYear}` : null].filter(Boolean).join(' · '),
                sevClass: `sev-pill ${toneFor(f.urgency)}`,
                hasPhotos: f.photos && f.photos.length > 0,
                photoCount: f.photos ? f.photos.length : 0,
                photos: f.photos || [],
                suggestion: this.suggestionView(this.photoSuggestions[f.id])
            }));
    }

    get activeEquipmentHasFindings() {
        return this.activeFindings.length > 0;
    }

    get activeEquipmentClear() {
        return this.clearEquipment.has(this.activeEquipment);
    }

    get canMarkClear() {
        return !this.activeEquipmentHasFindings && !this.activeEquipmentClear;
    }

    selectEquipment(event) {
        const value = event.currentTarget.dataset.equipment;
        this.activeEquipment = this.activeEquipment === value ? null : value;
        this.draft = null;
    }

    markClear() {
        const next = new Set(this.clearEquipment);
        next.add(this.activeEquipment);
        this.clearEquipment = next;
        this.activeEquipment = null;
    }

    // ---------- finding editor ----------
    get editing() {
        return !!this.draft;
    }

    get componentChips() {
        return this.chips(COMPONENTS, this.draft && this.draft.component, 'component');
    }

    get conditionChips() {
        return this.chips(CONDITIONS, this.draft && this.draft.condition, 'condition');
    }

    get urgencyChips() {
        return URGENCIES.map((u) => {
            const on = this.draft && this.draft.urgency === u.value;
            return {
                value: u.value,
                cls: `sev-chip ${u.tone}${on ? ' selected' : ''}`,
                ariaPressed: on ? 'true' : 'false'
            };
        });
    }

    chips(values, selected, field) {
        return values.map((v) => ({
            value: v,
            field,
            cls: v === selected ? 'chip selected' : 'chip',
            ariaPressed: v === selected ? 'true' : 'false'
        }));
    }

    get saveDisabled() {
        const d = this.draft;
        return this.saving || !d || (!d.component && !d.condition && !d.make && !d.installYear);
    }

    get editorTitle() {
        return this.draft && this.draft.id ? 'Edit finding' : 'New finding';
    }

    startFinding() {
        this.draft = emptyDraft(this.activeEquipment);
        this.resetDictation();
    }

    editFinding(event) {
        const f = this.findings.find((x) => x.id === event.currentTarget.dataset.id);
        if (f) {
            this.draft = {
                id: f.id,
                equipment: f.equipment,
                component: f.component,
                condition: f.condition,
                urgency: f.urgency || 'Monitor',
                make: f.make || '',
                modelNumber: f.modelNumber || '',
                serialNumber: f.serialNumber || '',
                installYear: f.installYear || null,
                reading: f.reading || '',
                customerNote: f.customerNote || '',
                internalNote: f.internalNote || ''
            };
        }
    }

    cancelFinding() {
        this.draft = null;
        this.resetDictation();
    }

    pickChip(event) {
        const { field, value } = event.currentTarget.dataset;
        const current = this.draft[field];
        this.draft = { ...this.draft, [field]: current === value ? null : value };
    }

    pickUrgency(event) {
        this.draft = { ...this.draft, urgency: event.currentTarget.dataset.value };
    }

    handleNote(event) {
        this.draft = { ...this.draft, [event.target.dataset.field]: event.target.value };
    }

    handleYear(event) {
        const year = parseInt(event.target.value, 10);
        this.draft = { ...this.draft, installYear: year > 1950 ? year : null };
    }

    async submitFinding() {
        this.saving = true;
        try {
            this.apply(await saveFinding({ assessmentId: this.assessmentId, finding: this.draft }));
            this.draft = null;
            this.resetDictation();
            const next = new Set(this.clearEquipment);
            next.delete(this.activeEquipment);
            this.clearEquipment = next;
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.saving = false;
        }
    }

    async removeFinding(event) {
        this.saving = true;
        try {
            this.apply(
                await deleteFinding({ assessmentId: this.assessmentId, findingId: event.currentTarget.dataset.id })
            );
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.saving = false;
        }
    }

    async handleUploadFinished(event) {
        const findingId = event.currentTarget.dataset.id;
        const documentIds = (event.detail && event.detail.documentIds) || [];
        this.apply(await getState({ assessmentId: this.assessmentId }));
        if (findingId && documentIds.length) {
            this.suggestFor(findingId, documentIds[documentIds.length - 1]);
        }
    }

    // ---------- Einstein: data plates and conditions from photos ----------
    async suggestFor(findingId, documentId) {
        this.setSuggestion(findingId, { loading: true });
        try {
            const s = await suggestFromPhoto({ findingId, documentId });
            const useful = s && (s.component || s.condition || s.make || s.installYear || s.observation);
            this.setSuggestion(findingId, useful ? s : null);
        } catch (e) {
            this.setSuggestion(findingId, null);
        }
    }

    setSuggestion(findingId, value) {
        const next = { ...this.photoSuggestions };
        if (value) next[findingId] = value;
        else delete next[findingId];
        this.photoSuggestions = next;
    }

    suggestionView(s) {
        if (!s) return null;
        const plate = [s.make, s.modelNumber, s.installYear ? `made ${s.installYear}` : null].filter(Boolean).join(' · ');
        return {
            ...s,
            ready: !s.loading,
            values: [plate, s.component, s.condition, s.urgency].filter(Boolean).join(' · ') || 'Nothing to note'
        };
    }

    dismissSuggestion(event) {
        this.setSuggestion(event.currentTarget.dataset.id, null);
    }

    /** Opens the finding with Einstein's values filled in; the technician checks them and saves. */
    reviewSuggestion(event) {
        const id = event.currentTarget.dataset.id;
        const f = this.findings.find((x) => x.id === id);
        const s = this.photoSuggestions[id];
        if (!f || !s) return;
        this.draft = {
            id: f.id,
            equipment: f.equipment,
            component: s.component || f.component,
            condition: s.condition || f.condition,
            urgency: s.urgency || f.urgency || 'Monitor',
            make: s.make || f.make || '',
            modelNumber: s.modelNumber || f.modelNumber || '',
            serialNumber: s.serialNumber || f.serialNumber || '',
            installYear: s.installYear || f.installYear || null,
            reading: f.reading || s.reading || '',
            customerNote: f.customerNote || s.customerNote || '',
            internalNote: f.internalNote || ''
        };
        this.filledBy = 'Filled in from the photo. Check it, then save.';
        this.setSuggestion(id, null);
    }

    // ---------- Einstein: voice notes into findings ----------
    get fillDisabled() {
        return this.parsing || !this.dictation || !this.dictation.trim();
    }

    get fillLabel() {
        return this.parsing ? 'Filling…' : 'Fill from notes';
    }

    handleDictation(event) {
        this.dictation = event.target.value;
    }

    resetDictation() {
        this.dictation = '';
        this.filledBy = undefined;
    }

    async fillFromNotes() {
        this.parsing = true;
        try {
            const s = await parseNotes({ notes: this.dictation, equipment: this.draft.equipment });
            this.draft = {
                ...this.draft,
                equipment: s.equipment || this.draft.equipment,
                component: s.component || this.draft.component,
                condition: s.condition || this.draft.condition,
                urgency: s.urgency || this.draft.urgency,
                reading: s.reading || this.draft.reading,
                installYear: s.installYear || this.draft.installYear,
                customerNote: s.customerNote || this.draft.customerNote,
                internalNote: s.internalNote || this.draft.internalNote
            };
            this.filledBy = s.aiGenerated
                ? 'Filled in by Einstein from your notes. Check it, then save.'
                : 'Filled in from keywords in your notes. Check it, then save.';
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.parsing = false;
        }
    }

    previewPhoto(event) {
        const { url, title } = event.currentTarget.dataset;
        this.viewing = { url, title };
    }

    closePhoto() {
        this.viewing = undefined;
    }

    // ---------- recommendation ----------
    get hasRecommendation() {
        return !!(this.recommendation && this.recommendation.reasons);
    }

    get reasons() {
        return ((this.recommendation && this.recommendation.reasons) || []).map((r) => ({
            ...r,
            key: r.sku,
            because: (r.because || []).map((text, i) => ({ key: `${r.sku}-${i}`, text }))
        }));
    }

    get replacementRecommended() {
        return !!(this.recommendation && this.recommendation.replacementRecommended);
    }

    get overallUrgency() {
        return (this.recommendation && this.recommendation.urgency) || 'Monitor';
    }

    get overallUrgencyClass() {
        return `sev-pill ${toneFor(this.overallUrgency)}`;
    }

    get oldestAgeLabel() {
        const age = this.recommendation && this.recommendation.oldestAge;
        return age === null || age === undefined ? '—' : `${age} yr`;
    }

    get photoTotal() {
        return this.findings.reduce((n, f) => n + (f.photos ? f.photos.length : 0), 0);
    }

    get findingTotal() {
        return this.findings.length;
    }

    @api
    validate() {
        if (this.editing) {
            return { isValid: false, errorMessage: 'Save or cancel the open finding before continuing.' };
        }
        if (this.checkedCount === 0) {
            return {
                isValid: false,
                errorMessage: 'Check at least one piece of equipment: add a finding or mark it good.'
            };
        }
        return { isValid: true };
    }
}

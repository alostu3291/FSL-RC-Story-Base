import { LightningElement, api } from 'lwc';
import getState from '@salesforce/apex/RLM_HVAC_FieldAddOn.getState';
import addAddOns from '@salesforce/apex/RLM_HVAC_FieldAddOn.addAddOns';
import removeAddOn from '@salesforce/apex/RLM_HVAC_FieldAddOn.removeAddOn';
import saveFinding from '@salesforce/apex/RLM_HVAC_Assessment.saveFinding';
import aiSuggestions from '@salesforce/apex/RLM_HVAC_FieldAddOn.aiSuggestions';

const EQUIPMENT = ['Outdoor Unit', 'Furnace', 'Air Handler', 'Heat Pump', 'Boiler', 'Thermostat', 'Ductwork', 'Water Heater', 'Indoor Air'];
const COMPONENTS = ['Capacitor', 'Contactor', 'Coil', 'Refrigerant', 'Blower Motor', 'Condensate Drain', 'Filter', 'Igniter',
    'Heat Exchanger', 'Flue / Venting', 'Thermostat', 'Airflow', 'Tank', 'Other'];
const CONDITIONS = ['Worn', 'Failed', 'Dirty', 'Leaking', 'Low Charge', 'Clogged', 'Cracked', 'Out of Range', 'Sediment'];
const URGENCIES = ['Monitor', 'Repair Soon', 'Safety'];
const emptyDraft = () => ({ equipment: null, component: null, condition: null, urgency: 'Repair Soon', reading: '', note: '' });

const money = (value) =>
    new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(value || 0);

/**
 * Find & Add: during a visit the technician logs what's new, picks the one-time repairs it calls
 * for, and the customer approves them on the device. Approved repairs are billed when the work
 * order is completed.
 */
export default class RlmHvacFindAndAdd extends LightningElement {
    @api recordId;
    state;
    open = false;
    logging = false;
    busy = false;
    error;
    selected = new Set();
    approver = '';
    draft = emptyDraft();
    /** Einstein's extra picks from the finding notes, sku to reason. Prices and approval are unchanged. */
    aiPicks = {};
    aiBusy = false;
    aiMessage;

    connectedCallback() {
        this.load();
    }

    async load() {
        try {
            this.apply(await getState({ recordId: this.recordId }));
        } catch (e) {
            this.error = this.message(e);
        }
    }

    apply(state) {
        this.state = state;
        if (!this.approver) this.approver = state.customerName || '';
        this.selected = new Set(
            [...this.selected].filter((sku) => state.addOns.some((a) => a.sku === sku && !a.added))
        );
    }

    message(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong';
    }

    // ---------- panel ----------
    toggle() {
        this.open = !this.open;
        this.error = undefined;
    }
    get toggleLabel() {
        return this.open ? 'Hide' : 'Find & Add';
    }
    get canEdit() {
        return this.state && !this.state.completed;
    }
    get isCompleted() {
        return this.state && this.state.completed;
    }
    get isLoading() {
        return !this.state && !this.error;
    }
    get hasLines() {
        return this.state && this.state.lines.length > 0;
    }
    get linesView() {
        return (this.state ? this.state.lines : []).map((l) => ({
            ...l,
            priceLabel: money(l.price),
            meta: `Approved by ${l.approvedBy}${l.billed ? ' · Billed' : ''}`,
            removable: !l.billed && !this.state.completed
        }));
    }
    get linesTotal() {
        return money(this.state && this.state.total);
    }
    get summary() {
        if (!this.hasLines) {
            return this.isCompleted
                ? 'No repairs on this visit.'
                : 'Log something new and add a repair the agreement doesn’t cover.';
        }
        const n = this.state.lines.length;
        return `${n} repair${n === 1 ? '' : 's'} approved · ${this.linesTotal}, billed when the visit is completed.`;
    }

    // ---------- log a finding ----------
    get canLog() {
        return this.canEdit && this.state.assessmentId;
    }
    startLog() {
        this.logging = true;
        this.draft = emptyDraft();
    }
    cancelLog() {
        this.logging = false;
    }
    chips(values, current, field) {
        return values.map((value) => ({
            value,
            key: `${field}-${value}`,
            field,
            cls: `chip${value === current ? ' on' : ''}`
        }));
    }
    get equipmentChips() {
        return this.chips(EQUIPMENT, this.draft.equipment, 'equipment');
    }
    get componentChips() {
        return this.chips(COMPONENTS, this.draft.component, 'component');
    }
    get conditionChips() {
        return this.chips(CONDITIONS, this.draft.condition, 'condition');
    }
    get urgencyChips() {
        return this.chips(URGENCIES, this.draft.urgency, 'urgency');
    }
    pick(event) {
        const { field, value } = event.currentTarget.dataset;
        this.draft = { ...this.draft, [field]: this.draft[field] === value ? null : value };
    }
    handleNote(event) {
        this.draft = { ...this.draft, note: event.target.value };
    }
    handleReading(event) {
        this.draft = { ...this.draft, reading: event.target.value };
    }
    get cannotSaveFinding() {
        return this.busy || !this.draft.equipment || !this.draft.component;
    }
    async saveLog() {
        this.busy = true;
        this.error = undefined;
        try {
            await saveFinding({
                assessmentId: this.state.assessmentId,
                finding: {
                    equipment: this.draft.equipment,
                    component: this.draft.component,
                    condition: this.draft.condition,
                    urgency: this.draft.urgency || 'Repair Soon',
                    reading: this.draft.reading,
                    customerNote: this.draft.note
                }
            });
            this.logging = false;
            await this.load();
            this.dispatchEvent(new CustomEvent('findingadded'));
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.busy = false;
        }
    }

    // ---------- pick + approve ----------
    get addOnsView() {
        const rank = (a) => (a.recommended ? 0 : this.aiPicks[a.sku] ? 1 : 2);
        return (this.state ? this.state.addOns : [])
            .map((a) => {
                const on = this.selected.has(a.sku);
                const ai = !a.recommended && !a.added && this.aiPicks[a.sku];
                return {
                    ...a,
                    rank: rank(a),
                    reason: a.reason || this.aiPicks[a.sku],
                    priceLabel: money(a.price),
                    cls: `addon${on ? ' on' : ''}${a.added ? ' added' : ''}`,
                    badge: a.added ? 'Added' : a.recommended ? 'Recommended' : ai ? 'Einstein suggests' : null,
                    badgeCls: a.added ? 'badge added' : ai ? 'badge ai' : 'badge',
                    disabled: a.added || !this.canEdit
                };
            })
            .sort((x, y) => x.rank - y.rank);
    }

    get aiLabel() {
        return this.aiBusy ? 'Reading the notes…' : 'Ask Einstein';
    }

    /** Reads the finding notes for repairs the fixed rules missed; the customer still approves. */
    async askEinstein() {
        this.aiBusy = true;
        this.aiMessage = undefined;
        try {
            const picks = await aiSuggestions({ recordId: this.recordId });
            const next = {};
            (picks || []).forEach((p) => {
                next[p.sku] = p.reason;
            });
            this.aiPicks = next;
            this.aiMessage = picks && picks.length
                ? `Einstein found ${picks.length} more from the notes. The customer still approves.`
                : 'Einstein didn’t find anything else in the notes.';
        } catch (e) {
            this.aiMessage = 'Einstein isn’t available right now. The rules still apply.';
        } finally {
            this.aiBusy = false;
        }
    }
    toggleAddOn(event) {
        const sku = event.currentTarget.dataset.sku;
        const next = new Set(this.selected);
        if (next.has(sku)) next.delete(sku);
        else next.add(sku);
        this.selected = next;
    }
    get selectedTotal() {
        return (this.state ? this.state.addOns : [])
            .filter((a) => this.selected.has(a.sku))
            .reduce((sum, a) => sum + (a.price || 0), 0);
    }
    get hasSelection() {
        return this.selected.size > 0;
    }
    get approveLabel() {
        return `Customer approves ${money(this.selectedTotal)}`;
    }
    get cannotApprove() {
        return this.busy || !this.hasSelection || !this.approver || !this.approver.trim();
    }
    handleApprover(event) {
        this.approver = event.target.value;
    }
    async approve() {
        this.busy = true;
        this.error = undefined;
        try {
            this.apply(
                await addAddOns({ recordId: this.recordId, skus: [...this.selected], approvedBy: this.approver })
            );
            this.selected = new Set();
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.busy = false;
        }
    }
    async remove(event) {
        this.busy = true;
        this.error = undefined;
        try {
            this.apply(await removeAddOn({ lineId: event.currentTarget.dataset.id }));
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.busy = false;
        }
    }
}

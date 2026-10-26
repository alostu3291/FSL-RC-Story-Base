import { LightningElement, api } from 'lwc';
import getState from '@salesforce/apex/RLM_RTK_FieldAddOn.getState';
import addAddOns from '@salesforce/apex/RLM_RTK_FieldAddOn.addAddOns';
import removeAddOn from '@salesforce/apex/RLM_RTK_FieldAddOn.removeAddOn';
import saveFinding from '@salesforce/apex/RLM_RTK_Inspection.saveFinding';

const ZONES = ['Exterior Perimeter', 'Garage', 'Kitchen', 'Bathrooms', 'Living Areas', 'Basement / Crawlspace', 'Attic', 'Yard'];
const PESTS = ['Ants', 'Spiders', 'Cockroaches', 'Rodents', 'Termites', 'Mosquitoes', 'Wasps / Bees', 'Bed Bugs', 'Other'];
const EVIDENCE = ['Live Activity', 'Droppings', 'Damage', 'Nest', 'Entry Point', 'Standing Water', 'Wood-to-Soil Contact', 'Moisture'];

const money = (value) =>
    new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(value || 0);

/**
 * Find & Add: during a visit the technician logs what's new, picks the one-time services it calls
 * for, and the customer approves them on the device. Approved add-ons are billed when the work
 * order is completed.
 */
export default class RlmRtkFindAndAdd extends LightningElement {
    @api recordId;
    state;
    open = false;
    logging = false;
    busy = false;
    error;
    selected = new Set();
    approver = '';
    draft = { zone: null, pest: null, evidence: null, note: '' };

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
        if (!this.hasLines) return 'Log something new and add a one-time service the plan doesn’t cover.';
        const n = this.state.lines.length;
        return `${n} add-on${n === 1 ? '' : 's'} approved · ${this.linesTotal}, billed when the visit is completed.`;
    }

    // ---------- log a finding ----------
    get canLog() {
        return this.canEdit && this.state.inspectionId;
    }
    startLog() {
        this.logging = true;
        this.draft = { zone: null, pest: null, evidence: null, note: '' };
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
    get zoneChips() {
        return this.chips(ZONES, this.draft.zone, 'zone');
    }
    get pestChips() {
        return this.chips(PESTS, this.draft.pest, 'pest');
    }
    get evidenceChips() {
        return this.chips(EVIDENCE, this.draft.evidence, 'evidence');
    }
    pick(event) {
        const { field, value } = event.currentTarget.dataset;
        this.draft = { ...this.draft, [field]: this.draft[field] === value ? null : value };
    }
    handleNote(event) {
        this.draft = { ...this.draft, note: event.target.value };
    }
    get cannotSaveFinding() {
        return this.busy || !this.draft.zone || !this.draft.pest;
    }
    async saveLog() {
        this.busy = true;
        this.error = undefined;
        try {
            await saveFinding({
                inspectionId: this.state.inspectionId,
                finding: {
                    zone: this.draft.zone,
                    pest: this.draft.pest,
                    evidence: this.draft.evidence,
                    severity: 'Moderate',
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
        return (this.state ? this.state.addOns : []).map((a) => {
            const on = this.selected.has(a.sku);
            return {
                ...a,
                priceLabel: money(a.price),
                cls: `addon${on ? ' on' : ''}${a.added ? ' added' : ''}`,
                badge: a.added ? 'Added' : a.recommended ? 'Recommended' : null,
                badgeCls: a.added ? 'badge added' : 'badge',
                disabled: a.added || !this.canEdit
            };
        });
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

import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';
import preview from '@salesforce/apex/RLM_HVAC_ContractQuote.preview';
import createQuote from '@salesforce/apex/RLM_HVAC_ContractQuote.createQuote';

const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2 });
const wholeMoney = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });
const APPROVAL_DISCOUNT = 15;

/** The planned maintenance contract for a property group, site by site, placed as one quote. */
export default class RlmHvacContractBuilder extends NavigationMixin(LightningElement) {
    // Quick actions can set recordId after connectedCallback, so load from the setter too.
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        const changed = value !== this._recordId;
        this._recordId = value;
        if (value && changed) this.load();
    }

    _recordId;
    plan;
    filterProgram = true;
    discountPercent = 0;
    startDate;
    expanded = {};
    result;
    busy = false;
    error;

    async load() {
        this.busy = true;
        try {
            this.plan = await preview({
                accountId: this._recordId,
                filterProgram: this.filterProgram,
                discountPercent: this.discountPercent
            });
            if (!this.startDate) this.startDate = this.plan.startDate;
            this.error = undefined;
        } catch (e) {
            this.error = this.message(e, 'Could not build the contract.');
        } finally {
            this.busy = false;
        }
    }

    message(e, fallback) {
        return (e && e.body && e.body.message) || (e && e.message) || fallback;
    }

    get hasSites() {
        return this.plan && this.plan.sites.length > 0;
    }

    get sites() {
        return this.plan.sites.map((s) => {
            const open = !!this.expanded[s.accountId];
            return {
                ...s,
                open,
                ariaExpanded: open ? 'true' : 'false',
                toggleIcon: open ? 'utility:chevrondown' : 'utility:chevronright',
                summary: `${s.unitCount} units · ${s.tons} tons${s.responseTier ? ' · ' + s.responseTier + ' response' : ''}`,
                compliance: s.trackedUnits ? `${s.trackedUnits} leak-tracked` : null,
                age: s.oldestYear ? `oldest ${s.oldestYear}` : null,
                monthlyLabel: money.format(s.monthly),
                lines: s.lines.map((l) => ({
                    ...l,
                    key: `${s.accountId}-${l.sku}`,
                    priceLabel: money.format(l.unitPrice),
                    listLabel: l.discountPercent ? money.format(l.listPrice) : null,
                    monthlyLabel: money.format(l.monthly)
                }))
            };
        });
    }

    get monthlyLabel() {
        return money.format(this.plan.monthly);
    }

    get annualLabel() {
        return wholeMoney.format(this.plan.annual);
    }

    get termLabel() {
        return `${this.startDate} to ${this.plan.endDate} · ${this.plan.paymentTerms} · billed monthly`;
    }

    get needsApproval() {
        return this.discountPercent >= APPROVAL_DISCOUNT;
    }

    get quoteLabel() {
        return this.needsApproval ? 'Create quote and send for approval' : 'Create contract quote';
    }

    get quoteDisabled() {
        return this.busy || !this.hasSites;
    }

    toggleSite(event) {
        const id = event.currentTarget.dataset.id;
        this.expanded = { ...this.expanded, [id]: !this.expanded[id] };
    }

    changeFilter(event) {
        this.filterProgram = event.target.checked;
        this.load();
    }

    changeDiscount(event) {
        const value = Number(event.target.value);
        this.discountPercent = Number.isFinite(value) ? Math.max(0, Math.min(value, 40)) : 0;
        this.load();
    }

    changeStart(event) {
        this.startDate = event.target.value;
    }

    async quote() {
        this.busy = true;
        this.error = undefined;
        try {
            this.result = await createQuote({
                accountId: this._recordId,
                filterProgram: this.filterProgram,
                discountPercent: this.discountPercent,
                startDate: this.startDate
            });
        } catch (e) {
            this.error = this.message(e, 'Could not create the contract quote.');
        } finally {
            this.busy = false;
        }
    }

    openQuote() {
        this.open(this.result ? this.result.quoteId : this.plan.openQuoteId);
    }

    openExisting() {
        this.open(this.plan.openQuoteId);
    }

    open(recordId) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, objectApiName: 'Quote', actionName: 'view' }
        });
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}

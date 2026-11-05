import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';
import getStatus from '@salesforce/apex/RLM_HVAC_CapitalProject.status';
import book from '@salesforce/apex/RLM_HVAC_CapitalProject.book';

const USD = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });
const POLL_MS = 5000;
const MAX_POLLS = 60;
const STEP_DETAIL = {
    'Crane Lift': 'Lifts the new units to the roof',
    Install: 'Completing it bills the install milestone',
    Commissioning: 'Completing it bills the final milestone'
};

/** Books a signed capital project with the customer's PO, then follows its milestones and work orders. */
export default class RlmHvacBookProject extends NavigationMixin(LightningElement) {
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
    status;
    poNumber = '';
    busy = false;
    error;
    polls = 0;
    timer;

    disconnectedCallback() {
        clearTimeout(this.timer);
    }

    async load() {
        try {
            this.status = await getStatus({ quoteId: this._recordId });
            if (!this.poNumber && this.status.poNumber) this.poNumber = this.status.poNumber;
            this.error = undefined;
            this.schedule();
        } catch (e) {
            this.error = this.message(e, 'Could not load the project.');
        }
    }

    message(e, fallback) {
        return (e && e.body && e.body.message) || (e && e.message) || fallback;
    }

    get notProject() {
        return !!this.status && !this.status.isProject;
    }

    get booked() {
        return !!this.status && this.status.orderStatus !== 'None';
    }

    get hasOrder() {
        return !!this.status && !!this.status.orderId;
    }

    get canBook() {
        return !!this.status && this.status.isProject && !this.booked;
    }

    get bookDisabled() {
        return this.busy || !this.poNumber.trim();
    }

    /** Waiting on the order, the deposit invoice or the first work order, which follow booking by a minute or two. */
    get settingUp() {
        const s = this.status;
        return this.booked && (s.orderStatus !== 'Activated' || !s.invoices.length || !s.steps[0].workOrderId);
    }

    get introText() {
        const s = this.status;
        return `Replaces ${s.unitCount} rooftop units at ${s.siteName} for ${USD.format(s.total)}, billed to the `
            + 'property group on Net 30. Booking bills the deposit; the crane lift, install and commissioning '
            + 'work orders follow in turn.';
    }

    get milestones() {
        const s = this.status;
        return s.milestones.map((m, i) => ({
            ...m,
            key: m.name,
            label: `${m.name} (${Number(m.percent)}%)`,
            icon: m.accomplished ? 'utility:success' : 'utility:clock',
            variant: m.accomplished ? 'success' : '',
            cls: `row${m.accomplished ? ' done' : ''}`,
            invoice: m.accomplished && s.invoices[i] ? s.invoices[i].documentNumber : ''
        }));
    }

    get orderText() {
        const s = this.status;
        return s.orderNumber ? `Order ${s.orderNumber} ${s.orderStatus.toLowerCase()} · PO ${s.poNumber}` : 'Placing the order';
    }

    get steps() {
        return this.status.steps.map((st) => {
            let detail = STEP_DETAIL[st.key];
            if (st.workOrderNumber) {
                const lines = st.lines ? ` · ${st.lines} units` : '';
                detail = `Work order ${st.workOrderNumber} · ${st.workOrderStatus}${lines}`;
            }
            return {
                ...st,
                detail,
                icon: st.done ? 'utility:success' : st.workOrderId ? 'utility:record' : 'utility:clock',
                variant: st.done ? 'success' : '',
                cls: `row${st.done ? ' done' : st.workOrderId ? ' active' : ''}`
            };
        });
    }

    get invoicedText() {
        const s = this.status;
        return `Invoiced ${USD.format(s.invoiced)} of ${USD.format(s.total)}`;
    }

    schedule() {
        clearTimeout(this.timer);
        if (this.settingUp && this.polls < MAX_POLLS) {
            this.polls++;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.timer = setTimeout(() => this.load(), POLL_MS);
        }
    }

    changePo(event) {
        this.poNumber = event.target.value || '';
    }

    async bookProject() {
        this.busy = true;
        this.error = undefined;
        try {
            this.status = await book({ quoteId: this._recordId, poNumber: this.poNumber });
            this.polls = 0;
            this.schedule();
        } catch (e) {
            this.error = this.message(e, 'Could not book the project.');
        } finally {
            this.busy = false;
        }
    }

    openOrder() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.status.orderId, objectApiName: 'Order', actionName: 'view' }
        });
    }

    openWorkOrder(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, objectApiName: 'WorkOrder', actionName: 'view' }
        });
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}

import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';
import getStatus from '@salesforce/apex/RLM_HVAC_ContractOrder.status';
import placeOrder from '@salesforce/apex/RLM_HVAC_ContractOrder.placeOrder';

const POLL_MS = 5000;
const MAX_POLLS = 60;

/** Books a signed contract quote with the customer's PO, then follows the site coverage as it is set up. */
export default class RlmHvacBookContract extends NavigationMixin(LightningElement) {
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
            this.error = this.message(e, 'Could not load the contract.');
        }
    }

    message(e, fallback) {
        return (e && e.body && e.body.message) || (e && e.message) || fallback;
    }

    get booked() {
        return !!this.status && this.status.orderStatus !== 'None';
    }

    get settingUp() {
        const s = this.status;
        return this.booked && !(s.siteCount > 0 && s.sitesCovered >= s.siteCount && s.upcomingVisits > 0);
    }

    get bookDisabled() {
        return this.busy || !this.poNumber.trim() || this.status.awaitingApproval;
    }

    get steps() {
        const s = this.status;
        const sites = s.siteCount || 0;
        return [
            {
                key: 'order',
                label: s.orderNumber ? `Order ${s.orderNumber} ${s.orderStatus.toLowerCase()}` : 'Placing the order',
                detail: s.poNumber ? `PO ${s.poNumber}` : '',
                done: s.orderStatus === 'Activated'
            },
            {
                key: 'assets',
                label: s.contractAssets ? `${s.contractAssets} contract assets created` : 'Creating the contract assets',
                detail: 'One per site and service',
                done: s.contractAssets > 0
            },
            {
                key: 'coverage',
                label: `${s.sitesCovered} of ${sites} sites have response coverage`,
                detail: '4-hour at restaurants and the data room, next business day at offices',
                done: sites > 0 && s.sitesCovered >= sites
            },
            {
                key: 'visits',
                label: s.maintenancePlans
                    ? `${s.maintenancePlans} site maintenance plans · ${s.unitsMaintained} rooftop units`
                    : 'Setting up site maintenance plans',
                detail: s.upcomingVisits ? `${s.upcomingVisits} quarterly visits scheduled from ${s.firstVisit}` : 'Quarterly visits',
                done: s.upcomingVisits > 0
            }
        ].map((step) => ({
            ...step,
            icon: step.done ? 'utility:success' : 'utility:clock',
            variant: step.done ? 'success' : '',
            cls: `step${step.done ? ' done' : ''}`
        }));
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

    async book() {
        this.busy = true;
        this.error = undefined;
        try {
            this.status = await placeOrder({ quoteId: this._recordId, poNumber: this.poNumber });
            this.polls = 0;
            this.schedule();
        } catch (e) {
            this.error = this.message(e, 'Could not book the contract.');
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

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}

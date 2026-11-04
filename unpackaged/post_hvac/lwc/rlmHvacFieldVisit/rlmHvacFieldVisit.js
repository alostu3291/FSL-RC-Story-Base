import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import getContext from '@salesforce/apex/RLM_HVAC_FieldVisit.getContext';
import startAssessment from '@salesforce/apex/RLM_HVAC_FieldVisit.startAssessment';
import createQuote from '@salesforce/apex/RLM_HVAC_FieldVisit.createQuote';
import startProposal from '@salesforce/apex/RLM_HVAC_FieldVisit.startProposal';
import proposalStatus from '@salesforce/apex/RLM_HVAC_FieldVisit.proposalStatus';
import placeOrder from '@salesforce/apex/RLM_HVAC_FieldVisit.placeOrder';
import orderStatus from '@salesforce/apex/RLM_HVAC_FieldVisit.orderStatus';
import tuneUpSlots from '@salesforce/apex/RLM_HVAC_FieldVisit.tuneUpSlots';
import bookTuneUp from '@salesforce/apex/RLM_HVAC_FieldVisit.bookTuneUp';
import completeVisit from '@salesforce/apex/RLM_HVAC_FieldVisit.completeVisit';
import getState from '@salesforce/apex/RLM_HVAC_Assessment.getState';
import explainPlan from '@salesforce/apex/RLM_HVAC_AI.explainPlan';

const STEPS = [
    { key: 'walk', label: 'Check' },
    { key: 'plan', label: 'Agreement' },
    { key: 'customer', label: 'Sign' },
    { key: 'done', label: 'Booked' }
];
const POLL_MS = 3000;
const PROPOSAL_POLLS = 40;
const ORDER_POLLS = 30;
const SIGN_POLLS = 400;

/**
 * Check & Quote for the Field Service mobile app: one quick action on the System Check
 * appointment (or its work order) that checks the equipment, prices the comfort agreement and
 * repairs, lets the customer review findings and sign, then books the Initial Tune-up by
 * activating the order.
 */
export default class RlmHvacFieldVisit extends LightningElement {
    _recordId;
    ctx;
    step = 'loading';
    busy = false;
    error;
    rec;
    proposal;
    order;
    signMessage;
    embedded = true;
    _timer;
    _signTimer;
    slots;
    slotsLoading = false;
    slotBusy = false;
    slotError;
    leftForDispatch = false;
    completing = false;
    completeError;
    visitCompleted;
    planExplanation;
    _explaining;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        const changed = value !== this._recordId;
        this._recordId = value;
        if (changed && value) this.init();
    }

    disconnectedCallback() {
        clearTimeout(this._timer);
        clearTimeout(this._signTimer);
    }

    message(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong';
    }

    async init() {
        this.error = undefined;
        try {
            this.ctx = await getContext({ recordId: this._recordId });
            if (!this.ctx.canAssess && !this.ctx.assessmentId) {
                this.step = 'blocked';
                return;
            }
            const stage = this.ctx.stage;
            if (stage === 'customer') {
                this.goCustomer();
            } else if (stage === 'order') {
                this.book();
            } else if (stage === 'done') {
                this.step = 'booking';
                this.pollOrder(0);
            } else {
                this.step = stage;
            }
        } catch (e) {
            this.error = this.message(e);
            this.step = 'blocked';
        }
    }

    // ---------- step chrome ----------
    get isLoading() {
        return this.step === 'loading';
    }
    get isBlocked() {
        return this.step === 'blocked';
    }
    get isStart() {
        return this.step === 'start';
    }
    get isWalk() {
        return this.step === 'walk';
    }
    get isPlan() {
        return this.step === 'plan';
    }
    get isCustomer() {
        return this.step === 'customer';
    }
    get isBooking() {
        return this.step === 'booking';
    }
    get isDone() {
        return this.step === 'done';
    }

    get showSteps() {
        return ['walk', 'plan', 'customer', 'booking', 'done'].includes(this.step);
    }

    get steps() {
        const current = this.step === 'booking' ? 'done' : this.step;
        const index = STEPS.findIndex((s) => s.key === current);
        return STEPS.map((s, i) => ({
            ...s,
            number: i + 1,
            cls: `step${i < index ? ' past' : ''}${i === index ? ' current' : ''}`
        }));
    }

    get accountName() {
        return this.ctx && this.ctx.accountName;
    }
    get serviceAddress() {
        return this.ctx && this.ctx.serviceAddress;
    }
    get postalCode() {
        return this.ctx && this.ctx.postalCode;
    }
    get assessmentId() {
        return this.ctx && this.ctx.assessmentId;
    }
    get quoteId() {
        return this.ctx && this.ctx.quoteId;
    }
    get workOrderNumber() {
        return this.ctx && this.ctx.workOrderNumber;
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    // ---------- start + walk ----------
    async begin() {
        this.busy = true;
        this.error = undefined;
        try {
            const assessmentId = await startAssessment({ workOrderId: this.ctx.workOrderId });
            this.ctx = { ...this.ctx, assessmentId };
            this.step = 'walk';
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.busy = false;
        }
    }

    async toPlan() {
        const walk = this.template.querySelector('c-rlm-hvac-system-walk');
        const check = walk ? walk.validate() : { isValid: true };
        if (!check.isValid) {
            this.error = check.errorMessage;
            return;
        }
        this.busy = true;
        this.error = undefined;
        try {
            const state = await getState({ assessmentId: this.assessmentId });
            this.rec = state.recommendation || {};
            this.step = 'plan';
            this.explain();
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.busy = false;
        }
    }

    /** Writes the plain-language "why this agreement" while the technician reviews it; the quote waits for it. */
    explain() {
        this.planExplanation = undefined;
        this._explaining = explainPlan({ assessmentId: this.assessmentId })
            .then((text) => {
                this.planExplanation = text;
            })
            .catch(() => {
                this.planExplanation = undefined;
            });
    }

    get showBrief() {
        return (this.isStart || this.isWalk) && this.ctx && this.ctx.workOrderId;
    }

    backToWalk() {
        this.error = undefined;
        this.step = 'walk';
    }

    // ---------- plan + quote ----------
    get recommendationJson() {
        return this.rec ? JSON.stringify(this.rec) : undefined;
    }
    get recPlanSku() {
        return this.rec && this.rec.planSku;
    }
    get recSystemType() {
        return this.rec && this.rec.systemType;
    }
    get recSystemCount() {
        return this.rec && this.rec.systemCount;
    }
    get recEquipmentAge() {
        return this.rec && this.rec.equipmentAge;
    }
    get recIaq() {
        return !!(this.rec && this.rec.includeIaq);
    }
    get recWaterHeater() {
        return !!(this.rec && this.rec.includeWaterHeater);
    }
    get recRepairSkus() {
        return this.rec && this.rec.repairSkus ? this.rec.repairSkus.join(',') : '';
    }

    async quote() {
        const plan = this.template.querySelector('c-rlm-hvac-assess-quote');
        const check = plan.validate();
        if (!check.isValid) {
            this.error = check.errorMessage;
            return;
        }
        this.busy = true;
        this.error = undefined;
        try {
            if (this._explaining) await this._explaining;
            const result = await createQuote({
                workOrderId: this.ctx.workOrderId,
                planSku: plan.planSku,
                systemType: plan.systemType,
                equipmentAge: plan.equipmentAge,
                systemCount: plan.systemCount,
                includeIaq: plan.includeIaq,
                includeWaterHeater: plan.includeWaterHeater,
                repairSkus: plan.repairSkus,
                overrideReason: plan.overrideReason
            });
            this.ctx = { ...this.ctx, quoteId: result.quoteId, quoteNumber: result.quoteNumber };
            this.goCustomer();
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.busy = false;
        }
    }

    // ---------- customer: findings, proposal, sign ----------
    async goCustomer() {
        this.step = 'customer';
        this.proposal = { status: 'Generating' };
        try {
            const status = await startProposal({ quoteId: this.quoteId });
            this.applyProposal(status, 0);
        } catch (e) {
            this.proposal = { status: 'Failed', message: this.message(e) };
        }
    }

    applyProposal(status, attempt) {
        this.proposal = status;
        if (status.status === 'Ready') {
            this.watchForSignature(0);
        }
        if (status.status === 'Generating') {
            if (attempt >= PROPOSAL_POLLS) {
                this.proposal = { status: 'Failed', message: 'The proposal is taking too long. Try again.' };
                return;
            }
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._timer = setTimeout(async () => {
                try {
                    this.applyProposal(
                        await proposalStatus({ processId: status.processId, quoteId: this.quoteId }),
                        attempt + 1
                    );
                } catch (e) {
                    this.proposal = { status: 'Failed', message: this.message(e) };
                }
            }, POLL_MS);
        }
    }

    get proposalReady() {
        return this.proposal && this.proposal.status === 'Ready';
    }
    get proposalGenerating() {
        return this.proposal && this.proposal.status === 'Generating';
    }
    get proposalFailed() {
        return this.proposal && this.proposal.status === 'Failed';
    }
    get proposalDocId() {
        return this.proposal && this.proposal.contentDocumentId;
    }
    get proposalTitle() {
        return this.proposal && this.proposal.title;
    }

    retryProposal() {
        this.goCustomer();
    }

    handleAccepted(event) {
        this.signMessage = event.detail && event.detail.message;
        this.book();
    }

    // The Field Service app does not always deliver Sign & Pay's accepted event, so also
    // watch the quote and book as soon as it is signed.
    watchForSignature(attempt) {
        clearTimeout(this._signTimer);
        if (this.step !== 'customer' || attempt >= SIGN_POLLS) return;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._signTimer = setTimeout(async () => {
            if (this.step !== 'customer') return;
            try {
                const ctx = await getContext({ recordId: this._recordId });
                if (this.step === 'customer' && ctx.signed) {
                    this.ctx = ctx;
                    this.book();
                    return;
                }
            } catch (e) {
                // keep watching; the sign panel shows its own errors
            }
            this.watchForSignature(attempt + 1);
        }, POLL_MS);
    }

    // ---------- book the Initial Tune-up ----------
    async book() {
        this.step = 'booking';
        this.error = undefined;
        try {
            this.order = await placeOrder({ quoteId: this.quoteId });
            this.pollOrder(0);
        } catch (e) {
            this.error = this.message(e);
        }
    }

    async pollOrder(attempt) {
        try {
            this.order = await orderStatus({ quoteId: this.quoteId });
        } catch (e) {
            this.error = this.message(e);
            return;
        }
        const activated = this.order.status === 'Activated';
        if (activated && this.order.tuneUpWorkOrderNumber) {
            this.finish();
            return;
        }
        if (attempt >= ORDER_POLLS) {
            if (activated) {
                this.finish();
            } else {
                this.error = 'The order has not been created yet. Close and reopen Check & Quote to check again.';
            }
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._timer = setTimeout(() => this.pollOrder(attempt + 1), POLL_MS);
    }

    retryBooking() {
        this.book();
    }

    // ---------- Initial Tune-up time ----------
    finish() {
        this.step = 'done';
        if (this.order.tuneUpAppointmentId && !this.order.tuneUpScheduledStart) {
            this.loadSlots();
        }
    }

    async loadSlots() {
        this.slotsLoading = true;
        this.slotError = undefined;
        try {
            this.slots = await tuneUpSlots({ appointmentId: this.order.tuneUpAppointmentId });
        } catch (e) {
            this.slots = [];
            this.slotError = this.message(e);
        } finally {
            this.slotsLoading = false;
        }
    }

    async pickSlot(event) {
        const start = event.currentTarget.dataset.start;
        this.slotBusy = true;
        this.slotError = undefined;
        try {
            this.order = await bookTuneUp({
                appointmentId: this.order.tuneUpAppointmentId,
                startTime: start,
                quoteId: this.quoteId
            });
        } catch (e) {
            this.slotError = this.message(e);
        } finally {
            this.slotBusy = false;
        }
    }

    leaveForDispatch() {
        this.leftForDispatch = true;
    }

    async completeCheck() {
        this.completing = true;
        this.completeError = undefined;
        try {
            this.visitCompleted = await completeVisit({ recordId: this._recordId });
        } catch (e) {
            this.completeError = this.message(e);
        } finally {
            this.completing = false;
        }
    }

    get showSlots() {
        return (
            this.isDone &&
            !this.leftForDispatch &&
            !!this.order &&
            !!this.order.tuneUpAppointmentId &&
            !this.order.tuneUpScheduledStart
        );
    }
    get hasSlots() {
        return this.slots && this.slots.length > 0;
    }
    get noSlots() {
        return !this.slotError && !this.hasSlots;
    }
    get slotOptions() {
        return (this.slots || []).map((s) => {
            const start = new Date(s.startTime);
            return {
                key: s.startTime,
                start: s.startTime,
                day: start.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' }),
                time: start.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })
            };
        });
    }
    get doneTitle() {
        return this.tuneUpWhen ? 'Tune-up booked' : 'Agreement active';
    }

    get bookingLabel() {
        if (!this.order || this.order.status === 'Creating') return 'Creating the order…';
        if (this.order.status !== 'Activated') return `Activating order ${this.order.orderNumber}…`;
        return `Order ${this.order.orderNumber} is active. Scheduling the Initial Tune-up…`;
    }

    get orderNumber() {
        return this.order && this.order.orderNumber;
    }
    get tuneUpNumber() {
        return this.order && this.order.tuneUpWorkOrderNumber;
    }
    get tuneUpWhen() {
        const start = this.order && this.order.tuneUpScheduledStart;
        if (!start) return null;
        return new Date(start).toLocaleString('en-US', {
            weekday: 'short',
            month: 'short',
            day: 'numeric',
            hour: 'numeric',
            minute: '2-digit'
        });
    }
}

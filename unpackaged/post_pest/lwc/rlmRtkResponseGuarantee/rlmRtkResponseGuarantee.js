import { LightningElement, api } from 'lwc';

const MINUTE = 60 * 1000;
const DUE_SOON_MINUTES = 4 * 60;

function duration(ms) {
    const minutes = Math.max(0, Math.round(ms / MINUTE));
    const days = Math.floor(minutes / 1440);
    const hours = Math.floor((minutes % 1440) / 60);
    const mins = minutes % 60;
    if (days) return `${days}d ${hours}h`;
    if (hours) return `${hours}h ${mins}m`;
    return `${mins}m`;
}

function when(value) {
    return new Date(value).toLocaleString('en-US', {
        weekday: 'short',
        hour: 'numeric',
        minute: '2-digit'
    });
}

/** Countdown to a Covered re-service's response guarantee, from its Re-service Response milestone. */
export default class RlmRtkResponseGuarantee extends LightningElement {
    @api response;
    now = Date.now();
    _timer;

    connectedCallback() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._timer = setInterval(() => {
            this.now = Date.now();
        }, 30 * 1000);
    }

    disconnectedCallback() {
        clearInterval(this._timer);
    }

    get due() {
        return new Date(this.response.dueBy).getTime();
    }
    get met() {
        return !!this.response.metAt;
    }
    get remaining() {
        return this.due - this.now;
    }
    get state() {
        if (this.met) return this.response.violated ? 'late' : 'met';
        if (this.remaining <= 0) return 'overdue';
        return this.remaining <= DUE_SOON_MINUTES * MINUTE ? 'soon' : 'ontrack';
    }

    get cardClass() {
        return `card ${this.state}`;
    }
    get title() {
        const pest = this.response.reportedPest ? ` · ${this.response.reportedPest}` : '';
        return `Re-service guarantee${pest}`;
    }
    get subtitle() {
        return this.response.guaranteeName ? `Covered by ${this.response.guaranteeName}` : 'Covered re-service';
    }
    get headline() {
        switch (this.state) {
            case 'met':
                return 'Response guarantee met';
            case 'late':
                return 'Arrived after the guarantee';
            case 'overdue':
                return `Overdue by ${duration(-this.remaining)}`;
            default:
                return `${duration(this.remaining)} left`;
        }
    }
    get detail() {
        if (this.met) {
            const margin = this.due - new Date(this.response.metAt).getTime();
            const spare = margin > 0 ? `, ${duration(margin)} to spare` : '';
            return `Arrived ${when(this.response.metAt)}${spare}. Deadline was ${when(this.response.dueBy)}.`;
        }
        return `Arrive by ${when(this.response.dueBy)}. Requested ${when(this.response.requestedAt)}; 48 hours, Sundays excluded.`;
    }
    get showBar() {
        return !this.met;
    }
    get barStyle() {
        const start = new Date(this.response.requestedAt).getTime();
        const span = Math.max(1, this.due - start);
        const used = Math.min(100, Math.max(0, ((this.now - start) / span) * 100));
        return `width: ${used.toFixed(1)}%`;
    }
}

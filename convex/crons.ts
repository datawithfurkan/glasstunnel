import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

// Account email records live 7 days (throttles need 24 hours); lab outbox
// entries live 1 day.
crons.daily("prune account email records", { hourUTC: 4, minuteUTC: 17 }, internal.email.pruneAuthEmails, {});

export default crons;

import { handle } from "../lib/core.js";

export default {
  fetch(request) {
    return handle(request, process.env, "sign");
  },
};

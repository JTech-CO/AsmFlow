/* AsmFlow — the routing parity bridge (HARNESS.md M7 DoD 1).
 *
 * `tests/route_oracle.py` states the routing rules in Python and
 * `src/routing/` states them in assembly. Checking that the two agree needs a
 * way to put the same scenario in front of both, and a scenario is a
 * configuration snapshot, a set of provider runtime states, and a request.
 *
 * This reads a corpus of scenarios as JSON, drives the assembly selector over
 * each, and writes what it decided as JSON. `tests/test_routing_parity.py`
 * generates the corpus, runs the oracle over the same input, and compares.
 *
 * It is test-only code and lives in the test binary alone. AGENTS.md invariant
 * 2 is untouched by it for two reasons: it decides nothing — every rule under
 * test is in the assembly it calls — and it knows no structure offsets. The
 * layouts stay in `include/routing.inc` and reach this file only through the
 * builders in `tests/asm/route_fixture.asm`, so a field that moves moves in one
 * place.
 */

#include <jansson.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- what the assembly provides ------------------------------------------ */

void af_rt_sizes(uint64_t *out7);

void *af_rt_set_provider(void *providers, uint64_t index, const char *id,
                         int64_t adapter, uint64_t capabilities, int64_t enabled);
void af_rt_provider_limits(void *provider, uint64_t max_concurrency,
                           uint64_t fail_threshold, uint64_t success_threshold,
                           uint64_t cooldown_ms);
void af_rt_set_target(void *targets, uint64_t index, int64_t provider_index,
                      const char *upstream_model, int64_t priority, int64_t weight);
void af_rt_set_route(void *route, const char *id, uint64_t families,
                     int64_t policy, void *targets, uint64_t target_count);
void af_rt_set_config(void *config, void *providers, uint64_t provider_count,
                      void *routes, uint64_t route_count);
int64_t af_rt_apply_state(void *routing, const char *provider_id, int64_t health,
                          uint64_t active, uint64_t latency_us,
                          uint64_t open_until_ns);
void af_rt_request_init(void *request, void *routing, void *config, void *route,
                        uint64_t family_bit, uint64_t required_caps);
void af_rt_request_set(void *request, uint64_t tried, uint64_t now_ns);
const char *af_rt_candidate_id(const void *candidates, uint64_t index);
uint64_t af_rt_candidate_index(const void *candidates, uint64_t index);
void af_rt_route_cursor(void *routing, const char *route_id, uint64_t cursor);

int64_t af_routing_init(void *routing);
void af_routing_free(void *routing);
int64_t af_route_candidates(const void *request, void *out, uint64_t max);
int64_t af_route_select(int64_t policy, const void *candidates, uint64_t count,
                        uint64_t cursor);

/* --- the enumerations, by the names the corpus uses ---------------------- */

static int64_t adapter_of(const char *name)
{
    if (name == NULL) {
        return 2; /* openai_dual */
    }
    if (strcmp(name, "openai_responses") == 0) {
        return 0;
    }
    if (strcmp(name, "openai_chat") == 0) {
        return 1;
    }
    return 2;
}

static int64_t policy_of(const char *name)
{
    if (name != NULL && strcmp(name, "round_robin") == 0) {
        return 1;
    }
    if (name != NULL && strcmp(name, "least_latency") == 0) {
        return 2;
    }
    return 0;
}

static int64_t health_of(const char *name)
{
    if (name == NULL) {
        return 0;
    }
    if (strcmp(name, "degraded") == 0) {
        return 1;
    }
    if (strcmp(name, "open") == 0) {
        return 2;
    }
    if (strcmp(name, "half_open") == 0) {
        return 3;
    }
    if (strcmp(name, "disabled") == 0) {
        return 4;
    }
    return 0;
}

/* AF_CAP_* in include/asmflow.inc order. */
static uint64_t capability_bit(const char *name)
{
    if (strcmp(name, "responses") == 0) {
        return 1;
    }
    if (strcmp(name, "chat_completions") == 0) {
        return 2;
    }
    if (strcmp(name, "streaming") == 0) {
        return 4;
    }
    if (strcmp(name, "tools") == 0) {
        return 8;
    }
    if (strcmp(name, "vision") == 0) {
        return 16;
    }
    if (strcmp(name, "json_schema") == 0) {
        return 32;
    }
    return 0;
}

static uint64_t capability_mask(json_t *array)
{
    uint64_t mask = 0;
    size_t index;
    json_t *value;

    if (!json_is_array(array)) {
        return 0;
    }
    json_array_foreach(array, index, value) {
        if (json_is_string(value)) {
            mask |= capability_bit(json_string_value(value));
        }
    }
    return mask;
}

/* AF_EPF_* */
static uint64_t family_bit(const char *name)
{
    return (name != NULL && strcmp(name, "responses") == 0) ? 1u : 2u;
}

static int64_t member_int(json_t *object, const char *key, int64_t fallback)
{
    json_t *value = json_object_get(object, key);

    if (json_is_integer(value)) {
        return (int64_t)json_integer_value(value);
    }
    return fallback;
}

static int member_bool(json_t *object, const char *key, int fallback)
{
    json_t *value = json_object_get(object, key);

    if (json_is_boolean(value)) {
        return json_is_true(value) ? 1 : 0;
    }
    return fallback;
}

static const char *member_string(json_t *object, const char *key, const char *fallback)
{
    json_t *value = json_object_get(object, key);

    if (json_is_string(value)) {
        return json_string_value(value);
    }
    return fallback;
}

/* --- one scenario --------------------------------------------------------- */

static json_t *run_case(json_t *scenario, const uint64_t *sizes)
{
    json_t *candidates = json_object_get(scenario, "candidates");
    size_t count = json_is_array(candidates) ? json_array_size(candidates) : 0;
    const char *policy_name = member_string(scenario, "policy", "priority");
    const char *family_name = member_string(scenario, "endpoint_family",
                                            "chat_completions");
    uint64_t cursor = (uint64_t)member_int(scenario, "cursor", 0);
    uint64_t now_ns = (uint64_t)member_int(scenario, "now_ns", 0);
    uint64_t required = capability_mask(json_object_get(scenario,
                                                        "required_capabilities"));
    uint64_t tried = 0;

    void *providers = calloc(count ? count : 1, sizes[0]);
    void *targets = calloc(count ? count : 1, sizes[1]);
    void *route = calloc(1, sizes[2]);
    void *config = calloc(1, sizes[3]);
    void *request = calloc(1, sizes[4]);
    void *found = calloc(count ? count : 1, sizes[5]);
    void *routing = calloc(1, sizes[6]);
    json_t *result = NULL;
    json_t *chosen = NULL;
    json_t *listed = NULL;
    int64_t produced = 0;
    int64_t selected = -1;

    if (!providers || !targets || !route || !config || !request || !found || !routing) {
        fprintf(stderr, "route_corpus: out of memory\n");
        exit(2);
    }
    af_routing_init(routing);

    for (size_t index = 0; index < count; index++) {
        json_t *entry = json_array_get(candidates, index);
        const char *id = member_string(entry, "provider_id", "");
        void *provider = af_rt_set_provider(
            providers, index, id,
            adapter_of(member_string(entry, "adapter", "openai_dual")),
            capability_mask(json_object_get(entry, "capabilities")),
            member_bool(entry, "enabled", 1));

        af_rt_provider_limits(provider,
                              (uint64_t)member_int(entry, "max_concurrency", 1),
                              (uint64_t)member_int(entry, "failure_threshold", 1),
                              (uint64_t)member_int(entry, "success_threshold", 1),
                              (uint64_t)member_int(entry, "open_cooldown_ms", 1000));

        af_rt_set_target(targets, index, (int64_t)index,
                         member_string(entry, "upstream_model", "m"),
                         member_int(entry, "priority", 0),
                         member_int(entry, "weight", 1));

        af_rt_apply_state(routing, id, health_of(member_string(entry, "state", "healthy")),
                          (uint64_t)member_int(entry, "active", 0),
                          (uint64_t)member_int(entry, "latency_us", 0),
                          (uint64_t)member_int(entry, "open_until_ns", 0));

        if (member_bool(entry, "already_tried", 0)) {
            tried |= (uint64_t)1 << index;
        }
    }

    af_rt_set_route(route, member_string(scenario, "route_id", "route"),
                    family_bit(family_name), policy_of(policy_name),
                    targets, count);
    af_rt_set_config(config, providers, count, route, 1);
    af_rt_request_init(request, routing, config, route, family_bit(family_name),
                       required);
    af_rt_request_set(request, tried, now_ns);

    produced = af_route_candidates(request, found, count ? count : 1);
    if (produced < 0) {
        produced = 0;
    }
    listed = json_array();
    for (int64_t index = 0; index < produced; index++) {
        const char *id = af_rt_candidate_id(found, (uint64_t)index);

        json_array_append_new(listed, json_string(id ? id : ""));
    }

    selected = af_route_select(policy_of(policy_name), found, (uint64_t)produced,
                               cursor);
    if (selected >= 0 && selected < produced) {
        const char *id = af_rt_candidate_id(found, (uint64_t)selected);

        chosen = json_string(id ? id : "");
    } else {
        chosen = json_null();
    }

    result = json_object();
    json_object_set_new(result, "candidates", listed);
    json_object_set_new(result, "selected", chosen);

    af_routing_free(routing);
    free(routing);
    free(found);
    free(request);
    free(config);
    free(route);
    free(targets);
    free(providers);
    return result;
}

/* --- entry point ---------------------------------------------------------- */

int af_route_corpus_main(const char *path)
{
    uint64_t sizes[7];
    json_error_t error;
    json_t *corpus = json_load_file(path, 0, &error);
    json_t *results = NULL;
    size_t index;
    json_t *scenario;
    char *text = NULL;

    if (corpus == NULL || !json_is_array(corpus)) {
        fprintf(stderr, "route_corpus: %s: %s\n", path,
                corpus == NULL ? error.text : "not an array");
        json_decref(corpus);
        return 2;
    }
    af_rt_sizes(sizes);

    results = json_array();
    json_array_foreach(corpus, index, scenario) {
        json_array_append_new(results, run_case(scenario, sizes));
    }

    text = json_dumps(results, JSON_COMPACT | JSON_PRESERVE_ORDER);
    if (text == NULL) {
        fprintf(stderr, "route_corpus: could not serialise the results\n");
        json_decref(results);
        json_decref(corpus);
        return 2;
    }
    printf("%s\n", text);
    /* The runner leaves through exit_group, which is a raw syscall and runs no
     * stdio teardown. Without this the corpus arrives truncated at whatever
     * the last buffer boundary was, which reads as a parser error rather than
     * as a lost write. */
    fflush(stdout);
    free(text);
    json_decref(results);
    json_decref(corpus);
    return 0;
}

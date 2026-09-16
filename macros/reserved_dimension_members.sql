{% macro unknown_member_key() %}-1{% endmacro %}
{% macro default_member_key() %}0{% endmacro %}
{#-
    Reserved surrogate-key values for a dimension's synthetic
    unknown/default member rows -- per the DIM_SALES_CHANNEL v1.1
    (EDW-77) precedent already live in this project:
      -1 = Unknown  (a real value existed upstream but doesn't map to
                      anything in this dimension -- a data-quality gap)
       0 = Not Applicable / no natural default (the foreign key
                      genuinely doesn't apply to this fact row)

    These are ALWAYS hardcoded literals in a UNION ALL onto the
    dimension's real rows -- never derived by hashing. xxhash64 is a
    64-bit hash and cannot be coerced to output exactly -1 or 0, so any
    "make the key land on a reserved value" logic belongs here, as a
    literal, not in the key macro. This was the specific blocker on the
    DIM_VENDOR EDW-25 review (vendor_key = xxhash64(...) is signed and
    can't deterministically produce a reserved 0/-1) and applies
    identically to any other xxhash64-keyed dimension.
-#}

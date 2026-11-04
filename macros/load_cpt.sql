{% macro load_cpt() %}
  {#-
    LOAD the cpt change point extension (https://github.com/hugr-lab/duck-changepoint)
    from the local build named by env var CPT_EXTENSION_PATH. Used as the
    pre-hook of fct_fx_regimes. The env var defaults to '' so parsing works
    without it; only an actual run of the model requires it.
  -#}
  {%- set path = env_var('CPT_EXTENSION_PATH', '') -%}
  {%- if execute and path == '' -%}
    {{ exceptions.raise_compiler_error(
        "with_changepoint needs the cpt extension: set CPT_EXTENSION_PATH to a built "
        ~ "cpt.duckdb_extension (see README, 'Change point example')") }}
  {%- endif -%}
  LOAD '{{ path }}'
{% endmacro %}

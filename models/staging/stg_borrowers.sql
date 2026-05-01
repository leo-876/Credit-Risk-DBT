{{
  config(
    materialized='view',
    tags=['staging', 'borrowers']
  )
}}

/*
  stg_borrowers
  -------------
  Lightly cleans and standardizes the raw borrower source.
  - Casts types
  - Normalises province codes to uppercase
  - Flags recently onboarded borrowers (< 90 days) for special treatment in
    credit reporting (thin-file risk)
*/

with source as (
    select * from {{ ref('raw_borrowers') }}
),

renamed as (
    select
        borrower_id,
        upper(province_code)                             as province_code,
        cast(onboarded_at as date)                       as onboarded_at,
        lower(credit_score_band)                         as credit_score_band,
        cast(is_active as boolean)                       as is_active,

        -- Derived
        datediff('day', cast(onboarded_at as date), current_date)
                                                         as days_since_onboarding,
        case
            when datediff('day', cast(onboarded_at as date), current_date)
                 < {{ var('reporting_lookback_days') }}
            then true
            else false
        end                                              as is_thin_file,

        -- Audit columns
        current_timestamp                                as _loaded_at

    from source
    where borrower_id is not null
)

select * from renamed

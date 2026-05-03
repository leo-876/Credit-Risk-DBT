/*
  SCD Type-2 snapshot of borrower credit band.
  Tracks when a borrower's credit score band changes over time -
  essential for vintage cohort analysis and regulatory look-back.

  Strategy: check - dbt compares the check_cols and inserts a new row
  when the score band changes.
*/

{% snapshot snap_borrower_credit_profile %}

{{
  config(
    target_schema='snapshots',
    unique_key='borrower_id',
    strategy='check',
    check_cols=['credit_score_band', 'is_active'],
    invalidate_hard_deletes=True
  )
}}

select
    borrower_id,
    province_code,
    credit_score_band,
    is_active,
    is_thin_file,
    onboarded_at,
    current_timestamp as source_updated_at
from {{ ref('stg_borrowers') }}

{% endsnapshot %}

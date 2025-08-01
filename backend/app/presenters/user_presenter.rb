# frozen_string_literal: true

class UserPresenter
  delegate :country_code, :citizenship_country_code, :street_address, :city, :state, :zip_code, :email,
           :documents, :business_name, :business_entity?, :display_country,
           :legal_name, :preferred_name, :display_name, :billing_entity_name, :unconfirmed_email,
           :created_at, :state, :city, :zip_code, :street_address, :bank_account, :contracts, :tax_id, :birth_date,
           :requires_w9?, :tax_information_confirmed_at, :minimum_dividend_payment_in_cents, :bank_accounts,
           :tax_id_status, private: true, to: :user, allow_nil: true

  def initialize(current_context:)
    @current_context = current_context
    @user = current_context.user
    @company = current_context.company
    @company_administrator = current_context.company_administrator
    @company_worker = current_context.company_worker
    @company_investor = current_context.company_investor
    @company_lawyer = current_context.company_lawyer
  end

  def zip_code_label
    country_code == "US" ? "Zip code" : "Postal code"
  end

  def personal_details_props
    {
      legal_name:,
      preferred_name:,
      country_code:,
      citizenship_country_code: citizenship_country_code || country_code,
    }
  end

  def billing_details_props
    {
      email:,
      country: user.display_country,
      country_code:,
      state:,
      city:,
      zip_code:,
      street_address:,
      billing_entity_name:,
      legal_type: business_entity? ? "BUSINESS" : "PRIVATE",
      unsigned_document_id: documents.unsigned.where.not(docuseal_submission_id: nil).first&.id,
    }
  end

  def logged_in_user
    roles = {}
    has_documents = documents.joins(:signatures).not_consulting_contract.or(documents.unsigned).exists?
    if user.company_administrator_for?(company)
      administrator = user.company_administrator_for(company)
      roles[Company::ACCESS_ROLE_ADMINISTRATOR] = {
        id: administrator.id.to_s,
        isInvited: !!user.invited_by&.company_worker_for?(company),
      }
    end
    if user.company_lawyer_for?(company)
      roles[Company::ACCESS_ROLE_LAWYER] = {
        id: user.company_lawyer_for(company).external_id,
      }
    end
    if user.company_investor_for?(company)
      investor = user.company_investor_for(company)
      roles[Company::ACCESS_ROLE_INVESTOR] = {
        id: investor.external_id,
        hasDocuments: has_documents,
        hasGrants: investor.equity_grants.accepted.eventually_exercisable.exists?,
        hasShares: investor.share_holdings.exists?,
        hasConvertibles: investor.convertible_securities.exists?,
        investedInAngelListRuv: investor.invested_in_angel_list_ruv,
      }
    end
    if user.company_worker_for?(company)
      worker = user.company_worker_for(company)
      roles[Company::ACCESS_ROLE_WORKER] = {
        id: worker.external_id,
        hasDocuments: has_documents,
        endedAt: worker.ended_at,
        payRateType: worker.pay_rate_type,
        role: worker.role,
        payRateInSubunits: worker.pay_rate_in_subunits,
      }
    end
    
    #eagerload companies & their associations to prevent N+1 queries
    all_companies = user.all_companies.includes(
      :bank_account,
      :primary_admin => :user,
      :company_investors => :user,
      :company_workers => :user
    )
    #eagerload user's roles for all companies & map them for quick access
    user_company_admins = user.company_administrators.index_by(&:company_id)
    user_company_investors = user.company_investors.index_by(&:company_id)
    user_company_workers = user.company_workers.index_by(&:company_id)

    companies_data = all_companies.compact.map do |c|
      is_admin = user_company_admins.key?(c.id)
      is_investor = user_company_investors.key?(c.id)

      flags = %w[company_updates].filter { Flipper.enabled?(_1, c) }
      flags.push("equity_compensation") if c.equity_compensation_enabled?
      flags.push("equity_grants") if c.equity_grants_enabled?
      flags.push("dividends")
      flags.push("quickbooks") if c.quickbooks_enabled?
      flags.push("tender_offers") if c.tender_offers_enabled?
      flags.push("cap_table") if c.cap_table_enabled?
      flags.push("lawyers") if c.lawyers_enabled?
      flags.push("expenses") if c.expenses_enabled?
      flags.push("option_exercising") if c.json_flag?("option_exercising")

      can_view_financial_data = is_admin || is_investor

      active_workers = c.company_workers.select(&:active?)
      active_worker_user_ids = active_workers.map(&:user_id)
      investor_count = is_admin ? c.company_investors.count { |inv| !active_worker_user_ids.include?(inv.user_id) } : nil
      contractor_count = is_admin ? active_workers.count : nil

      current_user_role = user_company_admins[c.id] || user_company_workers[c.id]

      {
        **company_navigation_props(
          company: c,
        ),
        address: {
          street_address: c.street_address,
          city: c.city,
          zip_code: c.zip_code,
          state: c.state,
          country_code: c.country_code,
          country: c.country_code ? ISO3166::Country[c.country_code]&.common_name : nil,
        },
        flags:,
        equityCompensationEnabled: c.equity_compensation_enabled,
        requiredInvoiceApprovals: c.required_invoice_approval_count,
        paymentProcessingDays: c.contractor_payment_processing_time_in_days,
        createdAt: c.created_at.iso8601,
        fullyDilutedShares: can_view_financial_data ? c.fully_diluted_shares : nil,
        valuationInDollars: can_view_financial_data ? c.valuation_in_dollars : nil,
        sharePriceInUsd: can_view_financial_data ? c.share_price_in_usd.to_s : nil,
        conversionSharePriceUsd: can_view_financial_data ? c.conversion_share_price_usd.to_s : nil,
        exercisePriceInUsd: can_view_financial_data ? c.fmv_per_share_in_usd.to_s : nil,
        investorCount: investor_count,
        contractorCount: contractor_count,
        primaryAdminName: c.primary_admin&.user&.name,
        completedPaymentMethodSetup: c.bank_account_ready?,
        isTrusted: c.is_trusted,
        checklistItems: c.checklist_items(current_user_role),
        checklistCompletionPercentage: c.checklist_completion_percentage(current_user_role),
      }
    end

    {
      companies: companies_data,
      id: user.external_id,
      currentCompanyId: company&.external_id,
      name: user.display_name,
      legalName: legal_name,
      preferredName: preferred_name,
      billingEntityName: billing_entity_name,
      roles:,
      hasPayoutMethodForInvoices: user.bank_account.present?,
      hasPayoutMethodForDividends: user.bank_account_for_dividends.present?,
      address: {
        street_address: user.street_address,
        city: user.city,
        zip_code: user.zip_code,
        state: user.state,
        country_code: user.country_code,
        country: user.country_code && ISO3166::Country[user.country_code].common_name,
      },
      email: user.display_email,
      onboardingPath: OnboardingState::User.new(user:, company:).redirect_path,
      taxInformationConfirmedAt: tax_information_confirmed_at&.iso8601,
    }
  end

  private
    attr_reader :current_context, :user, :company, :company_administrator, :company_worker, :company_investor, :company_lawyer

    def user_props
      result = common_props.merge(
        is_worker: company_worker.present?,
        is_investor: company_investor.present?,
        flags: {},
      )
      result[:has_documents] = documents.not_consulting_contract.or(documents.unsigned).exists?
      if company_worker.present?
        if company_worker.active?
          result[:flags][:cap_table] = true if company.is_gumroad? && company.cap_table_enabled?
        end
      end
      if company_investor.present?
        result[:flags][:cap_table] ||= true if company.cap_table_enabled?
        result[:flags][:option_exercising] = company.json_flag?("option_exercising")
        result[:flags][:equity_grants] = company.equity_grants_enabled?

        result[:flags][:tender_offers] ||= company.tender_offers_enabled?
      end
      result
    end

    def company_admin_props
      common_props.deep_merge(common_admin_props).merge(
        is_company_admin: true,
        is_invited: !!user.invited_by&.company_worker_for?(company)
      )
    end

    def company_lawyer_props
      common_props.deep_merge(common_admin_props).merge(is_company_lawyer: true)
    end

    def common_admin_props
      {
        flags: {
          equity_grants: company.equity_grants_enabled?,
          cap_table: company.cap_table_enabled?,

          tender_offers: company.tender_offers_enabled?,
          dividends: true,
          company_updates: company.company_updates_enabled?,
        },
      }
    end

    def common_props
      {
        company: company.present? ? {
          id: company.external_id,
          name: company.display_name,
          logo_url: company.logo_url,
        } : nil,
        companies: user.all_companies.compact.map do
          company_navigation_props(
            company: _1,
          )
        end,
        legal_name:,
      }
    end

    def company_navigation_props(company:)
      CompanyNavigationPresenter.new(user: current_context.user, company:).props
    end
end

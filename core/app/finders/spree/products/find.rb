module Spree
  module Products
    class Find
      def initialize(scope:, params:, current_currency: nil)
        @scope = scope

        ActiveSupport::Deprecation.warn('`current_currency` param is deprecated and will be removed in Spree 5') if current_currency

        if current_currency.present?
          ActiveSupport::Deprecation.warn(<<-DEPRECATION, caller)
            `current_currency` param is deprecated and will be removed in Spree 5.
            Please pass `:currency` in `params` hash instead.
          DEPRECATION
        end

        @ids              = String(params.dig(:filter, :ids)).split(',')
        @skus             = String(params.dig(:filter, :skus)).split(',')
        @store            = params[:store] || Spree::Store.default
        @price            = map_prices(String(params.dig(:filter, :price)).split(','))
        @currency         = current_currency || params.dig(:filter, :currency) || params[:currency]
        @taxons           = taxon_ids(params.dig(:filter, :taxons))
        @concat_taxons    = taxon_ids(params.dig(:filter, :concat_taxons))
        @name             = params.dig(:filter, :name)
        @options          = params.dig(:filter, :options).try(:to_unsafe_hash)
        @option_value_ids = params.dig(:filter, :option_value_ids)
        @sort_by          = params.dig(:sort_by)
        @deleted          = params.dig(:filter, :show_deleted)
        @discontinued     = params.dig(:filter, :show_discontinued)
        @properties       = params.dig(:filter, :properties)
        @in_stock         = params.dig(:filter, :in_stock)
        @backorderable    = params.dig(:filter, :backorderable)
        @purchasable      = params.dig(:filter, :purchasable)
      end

      def execute
        products = by_ids(scope)
        products = by_skus(products)
        products = by_price(products)
        products = by_currency(products)
        products = by_taxons(products)
        products = by_concat_taxons(products)
        products = by_name(products)
        products = by_options(products)
        products = by_option_value_ids(products)
        products = by_properties(products)
        products = include_deleted(products)
        products = include_discontinued(products)
        products = show_only_stock(products)
        products = show_only_backorderable(products)
        products = show_only_purchasable(products)
        products = ordered(products)

        products.distinct
      end

      private

      attr_reader :ids, :skus, :price, :currency, :taxons, :concat_taxons, :name, :options, :option_value_ids, :scope,
                  :sort_by, :deleted, :discontinued, :properties, :store, :in_stock, :backorderable, :purchasable

      def ids?
        ids.present?
      end

      def skus?
        skus.present?
      end

      def price?
        price.present?
      end

      def currency?
        currency.present?
      end

      def taxons?
        taxons.present?
      end

      def concat_taxons?
        concat_taxons.present?
      end

      def name?
        name.present?
      end

      def options?
        options.present?
      end

      def option_value_ids?
        option_value_ids.present?
      end

      def sort_by?
        sort_by.present?
      end

      def properties?
        properties.present? && properties.values.reject(&:empty?).present?
      end

      def by_ids(products)
        return products unless ids?

        products.where(id: ids)
      end

      def by_skus(products)
        return products unless skus?

        products.joins(:variants_including_master).where(spree_variants: { sku: skus })
      end

      def by_price(products)
        return products unless price?

        products.price_between(price.min, price.max)
      end

      def by_currency(products)
        return products unless currency?

        products.with_currency(currency)
      end

      def by_taxons(products)
        return products unless taxons?

        products.joins(:classifications).where(Classification.table_name => { taxon_id: taxons })
      end

      def by_concat_taxons(products)
        return products unless concat_taxons?

        product_ids = Spree::Product.
                      joins(:classifications).
                      where(Classification.table_name => { taxon_id: concat_taxons }).
                      group("#{Spree::Product.table_name}.id").
                      having("COUNT(#{Spree::Product.table_name}.id) = ?", concat_taxons.length).
                      ids

        products.where(id: product_ids)
      end

      def by_name(products)
        return products unless name?

        products.like_any([:name], [name])
      end

      def by_options(products)
        return products unless options?

        products_ids = options.map { |key, value| products.with_option_value(key, value).ids }
        products.where(id: products_ids.reduce(&:intersection))
      end

      def by_option_value_ids(products)
        return products unless option_value_ids?

        product_ids = Spree::Product.
                      joins(variants: :option_values).
                      where(spree_option_values: { id: option_value_ids }).
                      group("#{Spree::Product.table_name}.id, #{Spree::Variant.table_name}.id").
                      having('COUNT(spree_option_values.option_type_id) = ?', option_types_count(option_value_ids)).
                      distinct.
                      ids

        products.where(id: product_ids)
      end

      def by_properties(products)
        return products unless properties?

        product_ids = []
        index = 0

        properties.to_unsafe_hash.each do |property_filter_param, product_properties_values|
          next if property_filter_param.blank? || product_properties_values.empty?

          values = product_properties_values.split(',').reject(&:empty?).uniq.map(&:parameterize)

          next if values.empty?

          ids = products.with_property_values(property_filter_param, values).ids
          product_ids = index == 0 ? ids : product_ids & ids
          index += 1
        end

        products.where(id: product_ids)
      end

      def option_types_count(option_value_ids)
        Spree::OptionValue.
          where(id: option_value_ids).
          distinct.
          count(:option_type_id)
      end

      def ordered(products)
        return products unless sort_by?

        case sort_by
        when 'default'
          if taxons?
            products.ascend_by_taxons_min_position(taxons)
          else
            products
          end
        when 'name-a-z'
          products.order(name: :asc)
        when 'name-z-a'
          products.order(name: :desc)
        when 'newest-first'
          products.order(available_on: :desc)
        when 'price-high-to-low'
          products.
            select("#{Product.table_name}.*, #{Spree::Price.table_name}.amount").
            reorder('').
            send(:descend_by_master_price)
        when 'price-low-to-high'
          products.
            select("#{Product.table_name}.*, #{Spree::Price.table_name}.amount").
            reorder('').
            send(:ascend_by_master_price)
        end
      end

      def include_deleted(products)
        deleted ? products.with_deleted : products.not_deleted
      end

      def include_discontinued(products)
        discontinued ? products : products.active(currency)
      end

      def show_only_stock(products)
        return products unless in_stock.to_s == 'true'

        products.in_stock
      end

      def show_only_backorderable(products)
        return products unless backorderable.to_s == 'true'

        products.backorderable
      end

      def show_only_purchasable(products)
        return products unless purchasable.to_s == 'true'

        products.in_stock_or_backorderable
      end

      def map_prices(prices)
        prices.map do |price|
          price == 'Infinity' ? Float::INFINITY : price.to_f
        end
      end

      def taxon_ids(taxons_ids)
        return if taxons_ids.nil? || taxons_ids.to_s.blank?

        taxons = store.taxons.where(id: taxons_ids.to_s.split(','))
        taxons.map(&:cached_self_and_descendants_ids).flatten.compact.uniq.map(&:to_s)
      end
    end
  end
end

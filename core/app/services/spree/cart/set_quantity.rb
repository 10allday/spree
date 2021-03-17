module Spree
  module Cart
    class SetQuantity
      prepend Spree::ServiceModule::Base

      def call(order:, line_item:, quantity: nil)
        ActiveRecord::Base.transaction do
          run :change_item_quantity
          run :recalculate_service
        end
      end

      protected

      def change_item_quantity(order:, line_item:, quantity: nil)
        return failure(line_item) unless line_item.update(quantity: quantity)

        success(order: order, line_item: line_item)
      end

      def recalculate_service
        Spree::Dependencies.cart_recalculate_service.constantize
      end
    end
  end
end

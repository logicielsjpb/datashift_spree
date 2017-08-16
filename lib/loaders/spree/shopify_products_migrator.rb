  # Copyright:: (c) Autotelik Media Ltd 2010
# Author ::   Tom Statter
# Date ::     Aug 2010
# License::   MIT ?
#
# Details::   Specific over-rides/additions to support Spree Products
#
require 'spree_base_loader'
require 'spree_ecom'

module DataShift

  module SpreeEcom

    class ShopifyProductsMigrator < ProductLoader

      def initialize(product, options)
        @@shopify_to_spree_headers = {
          'Body (HTML)' => 'Description',
          'Title' => 'Name',
          'Variant SKU' => 'variant_sku',
          'Variant Price' => 'variant_price',
          'Variant Inventory Qty' => 'stock_items',
          'Image Src' => 'Images',
          'Tags' => 'Taxons'
        }

        @@option_name_regex = /Option(\d+) Name/

        @@published_col_name = 'Published'
        @@variant_sku_col_name = 'variant_sku'
        @@variant_price_col_name = 'variant_price'
        @@sku_col_name = "SKU"
        @@price_col_name = "Price"
        @@shipping_cat_col_name = "Shipping Category"
        @@variants_col_name = "Variants"
        @@handle_col_name = "Handle"
        @@taxons_col_name = "Taxons"
        @@stock_items_col_name = "stock_items"

        @@default_shipping_category = 'default'
        @@default_inventory = 'default'

        super(product, options)
      end

      # Overriding this method allows us to override columns from the Shopify
      # export before they get passed to the LoaderBase
      def populate_method_mapper_from_headers( headers, options = {} )
        @headers = headers

        # We need to check if a header is in the substitution list and change
        # its value to a Spree name. The comparison needs to be done using
        # regex since some columns have an index in their name. For instance,
        # options are splitted with Option1 Name, Option1 Value, Option2 Name,
        # Option2 value.
        @headers.map! do |h|
          key, new_val = convert_to_spree_column(h)

          ( new_val.nil? ) ? h : new_val
        end

        add_missing_columns

        update_taxons

        puts "Updated Headers: #{@headers.inspect}"

        merge_variants

        super(@headers, options)
      end

      private
      # Find the new header value if the header matches an element in
      # @@shopify_to_spree_headers hash.
      #
      # Shopify headers are located in the keys while the matching value in
      # Spree is the value. The header can be a literal string or a regex
      #
      # Return nil if header doesn't need conversion
      def convert_to_spree_column(header)
        matching_header = @@shopify_to_spree_headers.select {|k, v| k == header || header.match(k) }

        return nil if matching_header.blank?

        key, val = matching_header.first
      end

      # Because Shopify exports only a Variant SKU and Spree needs a SKU column,
      # We will use the variant sku as the default sku for products.
      #
      # Order of the columns has an impact on the import process. Hence, we need
      # To put SKU, Price and Shipping categories at the beginning for the
      # product to be created and we need to put the Variants column before the
      # variant_sku and variant_price column.
      def add_missing_columns
        # DO NOT ACCESS DATA FROM THE ROWS UNTIL THE END OF THIS METHOD.
        # OTHERWISE, COLUMNS INDEXES MIGHT BE WRONG.

        # SKU, price and shipping category must be defined early in the process
        @headers =
            [@@sku_col_name, @@shipping_cat_col_name, @@price_col_name] + @headers

        # Keep the index of variant_sku before we insert the Variants column
        # To know where to put the new column in the rows.
        variant_sku_col_idx = col_index(@@variant_sku_col_name)

        @headers.insert(variant_sku_col_idx, @@variants_col_name)

        @parsed_file.map! do |row|
          # create missing columns: SKU, Shipping Category, Price
          row = ['', @@default_shipping_category, ''] + row

          # Insert empty column before variant_sku for the variants column
          row.insert(variant_sku_col_idx, '')
          row
        end
      end

      # Variants are created in Shopify exported files by creating mutliple lines
      # with the same handle, only putting variant options, variant sku and
      # variant price as data for those variant lines. We need to merge the data
      # of those variant lines into the master line of the product to have only
      # one row per product
      def merge_variants
        variant_lines, @parsed_file =
            @parsed_file.partition {|row| variant_line?(row)}

        # Fetch indexes
        variant_col_idx = col_index(@@variants_col_name)
        handle_col_idx = col_index(@@handle_col_name)
        variant_sku_col_idx = col_index(@@variant_sku_col_name)
        variant_price_col_idx = col_index(@@variant_price_col_name)
        stocK_item_col_idx = col_index(@@stock_items_col_name)

        # Search for Option(\d+) Name
        options_headers = {}
        @headers.each_with_index do |h, i|
          if data = h.match(@@option_name_regex)
            #Store header index and the option number which is kept in $1
            options_headers[i] = {id: data[1].to_i}
          end
        end

        # Merge Variants Option Values in one column
        # - Search for matching variant rows with the handle
        # - Append the options to variants column.
        # - Append the values of those options in the variant rows in the main
        #   row Variants column
        # - Merge Variant prices in one column
        # - Merge variant skus in one column
        # - Merge variant inventory quantities and append the default inventory
        #   name.
        @parsed_file.map! do |row|
          variants_str = ''
          master_sku = get_value_by_header(@@variant_sku_col_name, row)

          # Extract variants for this specific row from the variants array
          variants, variant_lines =
              variant_lines.partition {|v| v[handle_col_idx] == row[handle_col_idx]}

          # Set the proper value for the sku and price columns
          unless variants.empty?
            # TODO improve the master SKU
            master_sku = master_sku.slice(0..4) # Take only the first =5 chars as the main sku
          end

          row[col_index(@@sku_col_name)] = master_sku
          row[col_index(@@price_col_name)] =
              get_value_by_header(@@variant_price_col_name, row)


          # Put the default inventory name beore the inventory qty
          row[stocK_item_col_idx] =
              "#{@@default_inventory}:#{row[stocK_item_col_idx]}"

          options_headers.each_pair do |key,val|
            if row[key]
              # Set the option name in the variants to simplify the merge
              variants.map! {|v| v[key] = row[key]; v}
              variants_str += ';' if val[:id] > 1
              variants_str += "#{row[key]}:#{row[key+1]}"
            end
          end

          # Don't set a variant_sku if only one variant in product
          row[variant_sku_col_idx] = nil if variants.empty?

          variants.each do |v|
            options_headers.each_pair do |key,val|
              if v[key]
                variants_str += '|' if val[:id] == 1
                variants_str += ';' if val[:id] > 1
                variants_str += "#{v[key]}:#{v[key+1]}"
              end
            end

            row[variant_sku_col_idx] += "|#{v[variant_sku_col_idx]}"
            row[variant_price_col_idx] += "|#{v[variant_price_col_idx]}"
            row[stocK_item_col_idx] += "|#{@@default_inventory}:#{v[stocK_item_col_idx]}"
          end

          row[variant_col_idx] = variants_str
          row
        end
      end

      # Tags on producst are separated by commas in Shopify. We need the pipe
      # operator in Spree
      def update_taxons
        @parsed_file.map! do |row|
          i = col_index(@@taxons_col_name)
          row[i].gsub!(',', '|') if row[i]
          row
        end
      end

      def col_index(col_name)
        @headers.index(col_name)
      end

      def get_value_by_header(col_name, row)
        return '' if  variant_line?(row)

        row[@headers.index(col_name)]
      end

      # If column Published is not set to TRUE, we have a variant line
      def variant_line?(row)
        row[col_index(@@published_col_name)].blank?
      end

      def with_variants?(handle)
        count = 0
        @parsed_file.each do |row|
          if row[col_index(@@handle_col_name)] == handle
            count += 1
          end
        end

        count
      end

    end
  end
end
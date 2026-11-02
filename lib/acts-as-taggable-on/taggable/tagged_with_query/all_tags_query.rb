# frozen_string_literal: true

module ActsAsTaggableOn
  module Taggable
    module TaggedWithQuery
      class AllTagsQuery < QueryBase
        def build
          return single_tag_scope if tag_list.size == 1

          taggable_ids = options[:match_all].present? ? taggables_with_exact_tag_count : taggables_with_all_tags

          taggable_model.where(taggable_arel_table[taggable_model.primary_key].in(taggable_ids))
                        .order(order_conditions)
                        .readonly(false)
        end

        private

        # A single tag keeps the original one-join query, so chaining on the
        # joined taggings columns (e.g. `.group(:created_at)`) and the row
        # cardinality stay exactly as before.
        def single_tag_scope
          tag = tag_list.first
          tagging_alias = tagging_arel_table.alias(tagging_alias(tag))
          arel_join = taggable_arel_table.join(tagging_alias).on(on_conditions(tag, tagging_alias))

          if options[:match_all].present?
            arel_join = arel_join.join(tagging_arel_table, Arel::Nodes::OuterJoin).on(match_all_on_conditions)
          end

          scope = taggable_model.joins(arel_join.join_sources)

          if options[:match_all].present?
            scope = scope.group(taggable_arel_table[taggable_model.primary_key])
                         .having(tagging_arel_table[:taggable_id].count.eq(matching_tags_count))
          end

          scope.order(order_conditions).readonly(false)
        end

        def on_conditions(tag, tagging_alias)
          tagging_filters(tagging_alias)
            .and(tagging_alias[:taggable_id].eq(taggable_arel_table[taggable_model.primary_key]))
            .and(tagging_alias[:tag_id].in(tag_arel_table.project(tag_arel_table[:id]).where(tag_match_type(tag))))
        end

        def match_all_on_conditions
          tagging_arel_table[:taggable_id].eq(taggable_arel_table[taggable_model.primary_key])
                                          .and(context_and_date_filters(tagging_arel_table))
        end

        # Multiple tags: one subquery over taggings joined to tags once, grouped
        # by taggable. Each requested tag gets its own HAVING clause, so a
        # wildcard pattern that matches several tags still counts once and
        # every pattern must match on its own.
        def taggables_with_all_tags
          tagging_arel_table
            .project(tagging_arel_table[:taggable_id])
            .join(tag_arel_table).on(tag_arel_table[:id].eq(tagging_arel_table[:tag_id]))
            .where(tagging_filters(tagging_arel_table).and(tags_match_type))
            .group(tagging_arel_table[:taggable_id])
            .having(each_tag_matched)
        end

        def each_tag_matched
          tag_list.map do |tag|
            Arel::Nodes::Case.new.when(tag_match_type(tag)).then(1).else(0).sum.gt(0)
          end.reduce(:and)
        end

        # Only taggables that already have every tag are counted, so match_all
        # never groups the whole taggings table for the model.
        def taggables_with_exact_tag_count
          tagging_arel_table
            .project(tagging_arel_table[:taggable_id])
            .where(
              context_and_date_filters(tagging_arel_table)
                .and(tagging_arel_table[:taggable_id].in(taggables_with_all_tags))
            )
            .group(tagging_arel_table[:taggable_id])
            .having(tagging_arel_table[:id].count.eq(matching_tags_count))
        end

        def matching_tags_count
          tag_arel_table.project(Arel.star.count).where(tags_match_type)
        end

        def tagging_filters(table)
          condition = context_and_date_filters(table)

          if (owner = options[:owned_by]).present?
            condition = condition.and(table[:tagger_id].eq(owner.id))
                                 .and(table[:tagger_type].eq(owner.class.base_class.to_s))
          end

          condition
        end

        def context_and_date_filters(table)
          condition = table[:taggable_type].eq(taggable_model.base_class.name)
          condition = condition.and(table[:created_at].gteq(options[:start_at])) if options[:start_at].present?
          condition = condition.and(table[:created_at].lteq(options[:end_at])) if options[:end_at].present?
          condition = condition.and(table[:context].eq(options[:on])) if options[:on].present?
          condition
        end

        def order_conditions
          order_by = []
          if options[:order_by_matching_tag_count].present? && options[:match_all].blank?
            order_by << tagging_arel_table.project(tagging_arel_table[Arel.star].count.as('taggings_count')).order('taggings_count DESC').to_sql
          end

          order_by << options[:order] if options[:order].present?
          order_by.join(', ')
        end

        def tagging_alias(tag)
          alias_base_name = taggable_model.base_class.name.downcase
          adjust_taggings_alias("#{alias_base_name[0..11]}_taggings_#{ActsAsTaggableOn::Utils.sha_prefix(tag)}")
        end
      end
    end
  end
end

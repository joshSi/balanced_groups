#ifndef BALANCEDGROUPMANAGER_H
#define BALANCEDGROUPMANAGER_H

#include "group_manager.h"

// BalancedGroupManager Struct
typedef struct {
    GroupManager gs;
    int** familiarity_matrix;
    int* member_indices;
} BalancedGroupManager;

// Function Prototypes
Error* add_member_bgs(BalancedGroupManager* bgs, char* member);
Error* remove_member_bgs(BalancedGroupManager* bgs, char* member);
Error* create_groups_bgs(BalancedGroupManager* bgs, char*** group_list);
void print_familiarity(BalancedGroupManager* bgs);
int evaluate_group(BalancedGroupManager* bgs, char** group);
void update_familiarity(BalancedGroupManager* bgs, char** group);
char*** calculate_balanced_groups(BalancedGroupManager* bgs, int group_count, char** members);
char*** create_balanced_groups(BalancedGroupManager* bgs, int group_count);
void free_balanced_group_system(BalancedGroupManager* bgs);
#endif // BALANCEDGROUPMANAGER_H

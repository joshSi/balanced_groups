#include "balanced_group_system.h"
#include "group_system.h"
#include <stdio.h>
#include <stdlib.h>

int main() {
    // Create a BalancedGroupSystem object
    BalancedGroupSystem* bgs = malloc(sizeof(BalancedGroupSystem));
    bgs->gs.members = malloc(5* sizeof(char*));
    bgs->gs.num_members = 0;
    bgs->gs.group_history = malloc(sizeof(char***));
    char* members[] = {"Alice", "Bob", "Charlie", "David", "Eve"};
    for(int i=0; i < 5; i++){
      bgs->gs.members[i] = members[i];
    }

    //Add members
    Error* error = add_member_bgs(bgs, "Frank");
    if(error->error_code != 0){
      printf("Error adding member: %s \n", error->error_message);
    }
    error = add_member_bgs(bgs, "Grace");
    if(error->error_code != 0){
      printf("Error adding member: %s \n", error->error_message);
    }
    //Remove member
    error = remove_member_bgs(bgs, "Alice");
    if(error->error_code != 0){
      printf("Error removing member: %s \n", error->error_message);
    }
    // Create some groups
    char** group1 = malloc(3* sizeof(char*));
    char* group_members1[] = {"Bob", "Charlie", "David"};
    for(int i = 0; i < 3; i++) {
        group1[i] = group_members1[i];
    }
    char** group2 = malloc(3* sizeof(char*));
    char* group_members2[] = {"Eve", "Frank", "Grace"};
    for(int i = 0; i < 3; i++) {
        group2[i] = group_members2[i];
    }
    char*** groups = malloc(2 * sizeof(char**));
    groups[0] = group1;
    groups[1] = group2;
    error = create_groups_bgs(bgs, groups);
    if(error->error_code != 0){
      printf("Error creating group: %s \n", error->error_message);
    }

    print_familiarity(bgs);
    
    //Evaluate a group
    int group_score = evaluate_group(bgs, group1);
    printf("Group Score: %d \n", group_score);

    printf("Testing the group validation function\n");
    char** invalid_groups = malloc(3*sizeof(char*));
    char* invalid_group_members[] = {"Bob", "Bob", "Charlie"};
    for(int i = 0; i < 3; i++){
      invalid_groups[i] = invalid_group_members[i];
    }
    char*** invalid_group_list = malloc(1*sizeof(char**));
    invalid_group_list[0] = invalid_groups;
    error = create_and_validate_groups(&(bgs->gs), invalid_group_list);
    if(error->error_code != 0){
      printf("Error creating and validating group: %s \n", error->error_message);
    }
    free_balanced_group_system(bgs);
    return 0;
}

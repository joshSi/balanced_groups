#include "balanced_group_manager.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

Error* add_member_bgs(BalancedGroupManager* bgs, char* member) {
    if (bgs == NULL || member == NULL) {
        Error* error = malloc(sizeof(Error));
        error->error_code = -1;
        error->error_message = "Invalid input";
        return error;
    }
    Error* error = add_member_gm(&(bgs->gs), member);
    if(error->error_code != 0) return error;
    bgs->familiarity_matrix = realloc(bgs->familiarity_matrix, (bgs->gs.num_members) * sizeof(int*));
    for(int i = 0; i < bgs->gs.num_members; i++){
      bgs->familiarity_matrix[i] = realloc(bgs->familiarity_matrix[i], (bgs->gs.num_members) * sizeof(int));
      for(int j = 0; j < bgs->gs.num_members; j++){
        bgs->familiarity_matrix[i][j] = 0;
      }
    }
    bgs->member_indices = realloc(bgs->member_indices, (bgs->gs.num_members) * sizeof(int));
    bgs->member_indices[bgs->gs.num_members-1] = bgs->gs.num_members -1;
    Error* success = malloc(sizeof(Error));
    success->error_code = 0;
    success->error_message = "Success";
    return success;
}

Error* remove_member_bgs(BalancedGroupManager* bgs, char* member) {
  if (bgs == NULL || member == NULL) {
    Error* error = malloc(sizeof(Error));
    error->error_code = -1;
    error->error_message = "Invalid input";
    return error;
  }
  int index = -1;
  for(int i = 0; i < bgs->gs.num_members; i++){
    if(strcmp(bgs->gs.members[i], member)==0){
      index = i;
      break;
    }
  }
  if(index == -1){
    Error* error = malloc(sizeof(Error));
    error->error_code = -2;
    error->error_message = "Member not found";
    return error;
  }
  
  Error* error = remove_member_gm(&(bgs->gs), member);
  if(error->error_code != 0) return error;
  for(int i = 0; i < bgs->gs.num_members; i++){
    bgs->familiarity_matrix[i] = realloc(bgs->familiarity_matrix[i], (bgs->gs.num_members - 1) * sizeof(int));
    for(int j = 0; j < bgs->gs.num_members; j++){
      if(index == i || index == j) {
        bgs->familiarity_matrix[i][j] = 0;
      }
    }
  }
  Error* success = malloc(sizeof(Error));
  success->error_code = 0;
  success->error->error_message = "Success";
  return success;
}

Error* create_groups_bgs(BalancedGroupManager* bgs, char*** group_list) {
  if (bgs == NULL || group_list == NULL) {
        Error* error = malloc(sizeof(Error));
        error->error_code = -1;
        error->error_message = "Invalid input";
        return error;
  }
  Error* error = create_groups(&(bgs->gs), group_list);
  if(error->error_code != 0) return error;
  for (int i = 0; i < bgs->gs.num_members; i++) {
    for (int j = i+1; j < bgs->gs.num_members; j++) {
        int index1 = -1;
        int index2 = -1;
        for(int k = 0; k<bgs->gs.num_members; k++){
          if(strcmp(bgs->gs.members[k],group_list[0][0])==0){
              index1=k;
          }
          if(strcmp(bgs->gs.members[k],group_list[0][1])==0){
              index2=k;
          }
          if(strcmp(bgs->gs.members[k],group_list[0][2])==0){
              index2=k;
          }
        }
        bgs->familiarity_matrix[index1][index2] += 1;
    }
  }
  Error* success = malloc(sizeof(Error));
  success->error_code = 0;
  success->error_message = "Success";
  return success;
}

void print_familiarity(BalancedGroupManager* bgs){
  if(bgs == NULL) return;
  for (int i = 0; i < bgs->gs.num_members; i++) {
    printf("  ");
    for(int j = 0; j < bgs->gs.num_members; j++){
      printf("%s, ", bgs->gs.members[j]);
    }
    printf("\n");
    for(int j = 0; j < bgs->gs.num_members; j++){
      for(int k = 0; k<bgs->gs.num_members;k++){
        printf("%d",bgs->familiarity_matrix[j][k]);
      }
      printf("\n");
    }
  }
}

int evaluate_group_bgs(BalancedGroupManager* bgs, char** group){
  if(bgs == NULL || group == NULL) return -1;
  int score = 0;
  for(int i = 0; i < 3; i++){
    for(int j = i + 1; j < 3; j++){
        score += bgs->familiarity_matrix[bgs->member_indices[group[i]]][bgs->member_indices[group[j]]];
    }
  }
  return score;
}

void update_familiarity_bgs(BalancedGroupManager* bgs, char** group){
  if(bgs == NULL || group == NULL) return;
  for(int i = 0; i < 3; i++){
    for(int j = i + 1; j < 3; j++){
      bgs->familiarity_matrix[bgs->member_indices[group[i]]][bgs->member_indices[group[j]]] += 1;
      bgs->familiarity_matrix[bgs->member_indices[group[j]]][bgs->member_indices[group[i]]] += 1;
    }
  }
}

char*** calculate_balanced_groups(BalancedGroupManager* bgs, int group_count, char** members){
  return NULL;
}

char*** create_balanced_groups(BalancedGroupManager* bgs, int group_count){
  return NULL;
}

void free_balanced_group_manager(BalancedGroupManager* bgs){
  if(bgs == NULL) return;
  free_groups_gm(&(bgs->gs));
}

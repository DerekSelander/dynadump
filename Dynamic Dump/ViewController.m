//
//  ViewController.m
//  dynadump_ios
//
//  Created by Derek Selander on 6/10/24.
//

#import "ViewController.h"
#import "DetailViewController.h"
#include "dynadump/dyld.h"
@interface ViewController () <UITableViewDelegate, UITableViewDataSource>
@property (weak, nonatomic) IBOutlet UITableView *tableView;


@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
}


- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return dsc_images_count();
}

// Row display. Implementers should *always* try to reuse cells by setting each cell's reuseIdentifier and querying for available reusable cells with dequeueReusableCellWithIdentifier:
// Cell gets various attributes set automatically based on table (separators) and data source (accessory views, editing controls)

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    const char *path = dsc_image_as_num((uint32_t)indexPath.row);
    NSString *pathStr = [NSString stringWithCString:path ? path : "?" encoding:NSUTF8StringEncoding];
    cell.textLabel.text = pathStr;
    return cell;
}


- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    NSIndexPath* indexPath = [self.tableView indexPathForSelectedRow];
    DetailViewController* vc = (DetailViewController*)[segue destinationViewController];
//    auto application = self.filteredInstalledApplications[indexPath.row];
//    vc.application = application;
//    auto pidInfo = self.processDictionary[application.canonicalExecutablePath];
//    vc.pidInfo = pidInfo;
}


@end
